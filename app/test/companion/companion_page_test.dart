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
import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/companion/companion_widget.dart';
import 'package:dsh_app/links/launcher_entries.dart';
import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/notify/chat_alerts.dart' show companionHostKey;
import 'package:dsh_app/speech/speech_settings.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/companion_agent_state.dart';
import 'package:dsh_app/tavern/tavern_card_scripts.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/companion/companion_chrome.dart';
import 'package:dsh_app/ui/companion/companion_log.dart';
import 'package:dsh_app/ui/companion/companion_memory_page.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/companion/companion_tasks_page.dart';
import 'package:dsh_app/ui/shell/system_entry_host.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/tavern/tavern_home_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_app/ui/workspace/directory_picker.dart';
import 'package:dsh_client/dsh_client.dart'
    show
        CompanionAffinityStore,
        CompanionMemory,
        CompanionMemoryScopeStore,
        CompanionMemoryStore,
        CompanionTaskStore,
        CompanionPublicLookupStore,
        CompanionHostTaskStore,
        CompanionHostTasksApi,
        CompanionReminderSpec,
        CompanionMapStore,
        MemoryBatch,
        MemoryRow,
        companionMemoryExtractionPrompt,
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
import '../support/companion_compare_peer.dart';
import '../support/companion_receipts_peer.dart';
import '../support/companion_map_platform_peer.dart';

Widget _app(
  Widget child, {
  List<Override> extra = const [],
  CompanionKeeper? phone,
  HostConnection? connection,
  Override? connectionOverride,
}) => ProviderScope(
  // By default there is no host: the page must stand on its own without one.
  overrides: [
    connectionOverride ?? activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(connection)),
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

class _MapsFullMode extends CompanionModeSetting {
  @override
  CompanionMode? build() => CompanionMode.full;
}

class _FindConnection extends Notifier<HostConnection?> {
  @override
  HostConnection? build() => null;
  void connect(HostConnection value) => state = value;
}

/// The full room's Host conversation, already made: a computer task names it
/// without the test standing up the Host's whole session API.
class _BoundSessions extends CompanionSessions {
  static const id = 'companion-host-session';

  @override
  Future<CompanionBinding> ensure({String? memoryArchiveId, int? memoryControlRevision}) async =>
      CompanionBinding(id, memoryArchiveId: memoryArchiveId, memoryControlRevision: memoryControlRevision);
}

/// Computer tools are offered only in a connected full room now (light is
/// the phone alone): the overrides a Host task test opens the room with.
List<Override> get _hostRoom => [
  companionModeProvider.overrideWith(_MapsFullMode.new),
  companionSessionsProvider.overrideWith(_BoundSessions.new),
];

/// Skipped, product divergence: a map handoff whose scope the person left
/// for an unrelated page still shows 查看地址 when they come back. The Agent's
/// map_open calls ui.accepted (adding the pill) when the task is created,
/// before mapHandoff.execute; the old Page only presented a map result if the
/// window and handoff generation were still current at the end.
const _routeMapPillGap = false;

/// What her model asks for when told [receiptSpokenExample]: the four chosen
/// receipts into a new 差旅小表.xlsx by eight tonight, carrying on after she leaves.
const _receiptsCall = (
  'receipts_to_sheet',
  <String, Object?>{
    'operation': 'create',
    'afterExit': 'continue',
    'allowQueue': true,
    'deadlineTime': '20:00',
    'outputName': '差旅小表.xlsx',
  },
);

/// What her model asks for when told [compareSpokenExample]: A then B by
/// eight tonight, carrying on after she leaves.
const _compareCall = (
  'compare_drafts',
  <String, Object?>{'operation': 'create', 'afterExit': 'continue', 'allowQueue': true, 'deadlineTime': '20:00'},
);

/// The peer calls that are task work (task API, directory browsing), not the
/// full room's own visit (vitals, usage, memory migration).
Iterable<({String method, Uri uri, MemoryRow? body})> _taskCalls(NotesPeer peer) =>
    peer.calls.where((call) => call.uri.path.startsWith(notesPath) || call.uri.path.startsWith('/api/directoryPicker'));

final _findConnectionProvider = NotifierProvider<_FindConnection, HostConnection?>(_FindConnection.new);

Future<void> _notesVisible(WidgetTester tester, Finder finder, {bool absent = false}) async {
  for (var i = 0; i < 200 && (finder.evaluate().isEmpty != absent); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(finder, absent ? findsNothing : findsWidgets);
}

/// The app in front, as on a phone (a widget test starts with no lifecycle
/// state): a Host task's pickers need this real foreground room.
void _resumeApp(WidgetTester tester) {
  final before = tester.binding.lifecycleState;
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() {
    if (before != null) {
      tester.binding.handleAppLifecycleStateChanged(before);
    } else {
      tester.binding.resetInternalState();
    }
  });
}

/// Observes the Page's real completion future; all receipt handling stays
/// with the production owner. The story replay waits for it before leaving.
class _ReceiptMemory extends CompanionMemoryOwner {
  _ReceiptMemory(super.store, super.legacy, {super.nowMilliseconds});

  late Future<void> lastReceipt;
  ValueChanged<Future<void>>? receiptStarted;

  /// Every receipt retained so far: an Agent turn retains several (the turn,
  /// each model request, each tool call).
  final receipts = <Future<void>>[];

  @override
  void retainReceipt(Future<void> settled) {
    super.retainReceipt(settled);
    lastReceipt = settled;
    receipts.add(settled);
    receiptStarted?.call(settled);
  }
}

/// Also records the room the Page's visit entered: memory work now belongs to
/// the process-level agent's visit, not to the Page's State (A1).
class _RoomMemory2 extends _ReceiptMemory {
  _RoomMemory2(super.store, super.legacy);

  Object? room;

  @override
  void enter(
    Object room, {
    required FutureOr<CompanionMemoryTransport?> Function() transport,
    required int Function(String) estimateTokens,
    String? characterId,
    bool ready = true,
  }) {
    this.room = room;
    super.enter(
      room,
      transport: transport,
      estimateTokens: estimateTokens,
      characterId: characterId,
      ready: ready,
    );
  }
}

/// Waits until every receipt [memory] has retained, including ones retained
/// while waiting, has settled: the whole Agent turn, all its model rounds.
Future<void> _drained(WidgetTester tester, _ReceiptMemory memory) async {
  for (var seen = 0; seen < memory.receipts.length;) {
    final batch = memory.receipts.sublist(seen);
    seen = memory.receipts.length;
    await settleMixed(tester, Future.wait(batch.map((receipt) => receipt.catchError((Object _) {}))));
  }
  await tester.pump();
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

/// One complete phone-model reply on the light Messages endpoint: optional
/// words, then the model's own tool_use blocks (id, name, input) with the
/// matching stop reason. Only the model plans tasks and memory changes now.
http.Response _reply2({String? words, List<(String, String, Map<String, Object?>)> calls = const []}) {
  var index = 0;
  final events = <Map<String, Object?>>[
    {
      'type': 'message_start',
      'message': {
        'role': 'assistant',
        'content': <Object?>[],
        'usage': {'input_tokens': 10, 'output_tokens': 0},
      },
    },
    if (words != null) ...[
      {
        'type': 'content_block_start',
        'index': index,
        'content_block': {'type': 'text', 'text': ''},
      },
      {
        'type': 'content_block_delta',
        'index': index,
        'delta': {'type': 'text_delta', 'text': words},
      },
      {'type': 'content_block_stop', 'index': index++},
    ],
    for (final (id, name, input) in calls) ...[
      {
        'type': 'content_block_start',
        'index': index,
        'content_block': {'type': 'tool_use', 'id': id, 'name': name, 'input': <String, Object?>{}},
      },
      {
        'type': 'content_block_delta',
        'index': index,
        'delta': {'type': 'input_json_delta', 'partial_json': jsonEncode(input)},
      },
      {'type': 'content_block_stop', 'index': index++},
    ],
    {
      'type': 'message_delta',
      'delta': {'stop_reason': calls.isEmpty ? 'end_turn' : 'tool_use'},
      'usage': {'input_tokens': 10, 'output_tokens': 5},
    },
    {'type': 'message_stop'},
  ];
  return http.Response.bytes(
    utf8.encode([for (final event in events) 'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n'].join()),
    200,
    headers: {'content-type': 'text/event-stream; charset=utf-8'},
  );
}

/// The memory maintenance context this request carries, or null for any other
/// request. Upkeep offers memory tools too (A2), so only its first user
/// message, a `memory_maintenance_context` envelope, tells it apart.
Map<String, Object?>? _maintenanceInput2(Map<String, Object?> body) {
  final messages = body['messages'];
  if (messages is! List || messages.isEmpty) return null;
  final first = messages.first;
  if (first is! Map || first['role'] != 'user' || first['content'] is! String) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(first['content'] as String);
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['type'] != 'memory_maintenance_context') return null;
  return Map<String, Object?>.from(decoded);
}

/// The room's own chat turn (it always offers tools), not memory upkeep,
/// lookup answers or adapter requests, which go to the same endpoint.
bool _isChat2(Map<String, Object?> body) => body['tools'] is List && _maintenanceInput2(body) == null;

/// The tool results this continuation carries back to the model.
List<Map<String, Object?>> _toolResults2(Map<String, Object?> body) {
  final last = (body['messages']! as List).last as Map;
  final content = last['content'];
  if (last['role'] != 'user' || content is! List) return const [];
  return [
    for (final part in content.cast<Map>())
      if (part['type'] == 'tool_result') Map<String, Object?>.from(part),
  ];
}

/// The decoded body of the single tool result in this continuation.
Map<String, Object?> _toolResult2(Map<String, Object?> body) =>
    jsonDecode(_toolResults2(body).single['content']! as String) as Map<String, Object?>;

/// Waits on real and fake time together until [done] holds, bounded.
Future<void> _until2(WidgetTester tester, bool Function() done, {int rounds = 400}) async {
  for (var i = 0; i < rounds && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done(), isTrue, reason: 'the awaited condition never held');
}

/// Messages stream events as DeepSeek's Anthropic-compatible endpoint sends them.
String _messageEvents(List<Map<String, Object?>> events) =>
    [for (final event in events) 'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n'].join();

/// One model round that asks for [name] with [input] (and may say [words] first).
List<Map<String, Object?>> _toolTurn(String id, String name, Map<String, Object?> input, {String? words}) => [
  if (words != null)
    {
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'text_delta', 'text': words},
    },
  {
    'type': 'content_block_start',
    'index': 1,
    'content_block': {'type': 'tool_use', 'id': id, 'name': name, 'input': <String, Object?>{}},
  },
  {
    'type': 'content_block_delta',
    'index': 1,
    'delta': {'type': 'input_json_delta', 'partial_json': jsonEncode(input)},
  },
  {'type': 'content_block_stop', 'index': 1},
  {
    'type': 'message_delta',
    'delta': {'stop_reason': 'tool_use'},
    'usage': {'output_tokens': 5},
  },
  {'type': 'message_stop'},
];

/// A final model round: only words.
List<Map<String, Object?>> _wordsTurn(String text) => [
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'text_delta', 'text': text},
  },
  {
    'type': 'message_delta',
    'delta': {'stop_reason': 'end_turn'},
    'usage': {'output_tokens': 3},
  },
  {'type': 'message_stop'},
];

/// The tool results the latest request carries back, decoded, in call order.
List<Map<String, Object?>> _toolResults(Map<String, Object?> body) {
  final last = (body['messages']! as List).last as Map;
  final content = last['content'];
  if (content is! List) return const [];
  return [
    for (final block in content)
      if (block is Map && block['type'] == 'tool_result')
        {'tool_use_id': block['tool_use_id'], ...jsonDecode(block['content']! as String) as Map<String, Object?>},
  ];
}

/// The person's own words this request answers (the last line: lines she
/// never answered are joined into one user message), and how many tool rounds
/// of this turn have already come back.
({String said, int round}) _turnOf(Map<String, Object?> body) {
  final messages = (body['messages']! as List).cast<Map<String, Object?>>();
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    if (message['role'] != 'user') continue;
    final content = message['content'];
    final String? text = content is String
        ? content
        : content is List && content.isNotEmpty && (content.first as Map)['type'] == 'text'
        ? (content.first as Map)['text'] as String
        : null;
    if (text != null) {
      return (said: text.split('\n').last, round: messages.skip(i + 1).where((m) => m['role'] == 'assistant').length);
    }
  }
  throw StateError('A request without the person\'s words');
}

/// Her phone model in the light-room Agent loop. Each request gets the round
/// [answer] returns for it (index counts every request in this test).
class _AgentModel {
  _AgentModel(this.answer);

  /// For each thing the person says, asks for the calls [plan] gives, one per
  /// round, then says [reply]. A call's input may be a function of the
  /// previous round's results (for an ID it read first).
  factory _AgentModel.script(
    List<(String name, Object input)> Function(String said) plan, {
    String reply = '嗯。',
    Map<String, String> replies = const {},
  }) => _AgentModel((index, body) {
    // Memory upkeep shares the client: it may change nothing and end.
    if (_maintenanceInput2(body) != null) return _wordsTurn('');
    final turn = _turnOf(body);
    final calls = plan(turn.said);
    if (turn.round >= calls.length) return _wordsTurn(replies[turn.said] ?? reply);
    final (name, input) = calls[turn.round];
    final resolved = input is Map<String, Object?> Function(List<Map<String, Object?>>)
        ? input(_toolResults(body))
        : input as Map<String, Object?>;
    return _toolTurn('call-$index', name, resolved);
  });

  final List<Map<String, Object?>> Function(int index, Map<String, Object?> body) answer;
  final requests = <Map<String, Object?>>[];

  late final http.Client client = MockClient.streaming((request, body) async {
    final decoded = jsonDecode(await body.bytesToString()) as Map<String, Object?>;
    requests.add(decoded);
    return http.StreamedResponse(Stream.value(utf8.encode(_messageEvents(answer(requests.length - 1, decoded)))), 200);
  });

  /// Her chat rounds: the memory worker shares this phone client, and its
  /// upkeep offers memory tools too, but opens with its maintenance context.
  List<Map<String, Object?>> get chats => [
    for (final request in requests)
      if (request['tools'] != null && _maintenanceInput2(request) == null) request,
  ];

  /// Tool names offered with each chat round.
  List<List<String>> get offered => [
    for (final request in chats) [for (final tool in request['tools']! as List) (tool as Map)['name']! as String],
  ];

  /// Every tool result sent back, across chat rounds.
  List<Map<String, Object?>> get results => [for (final request in chats) ..._toolResults(request)];
}

/// Her phone model for one offline Host-task turn: the selected computer is
/// not connected, so only originals saved earlier can be chosen. For [said]
/// it asks once for [call]; after the real tool result it ends with
/// [failureLine] when that result is the actual selection_cancelled failure
/// (nothing saved to choose), or a plain 嗯。 once the task was accepted.
/// Memory upkeep also offers tools, so it is told apart by its maintenance
/// JSON envelope and answered with an ordinary end_turn.
class _OfflineTaskModel {
  _OfflineTaskModel(this.said, this.call, {this.failureLine});

  final String said;
  final (String, Map<String, Object?>) call;
  final String? failureLine;

  /// Her chat rounds for [said]; maintenance requests are kept apart.
  final ordinary = <Map<String, Object?>>[];
  final maintenance = <Map<String, Object?>>[];

  /// Requests that broke the script, checked in the test body.
  final problems = <String>[];
  String? issuedId;

  late final _model = _AgentModel(_answer);
  http.Client get client => _model.client;

  static bool _isMaintenance(Map<String, Object?> body) {
    final content = ((body['messages']! as List).first as Map)['content'];
    if (content is! String) return false;
    try {
      final input = jsonDecode(content);
      return input is Map && input['type'] == 'memory_maintenance_context';
    } on FormatException {
      return false;
    }
  }

  List<Map<String, Object?>> _problem(String what) {
    problems.add(what);
    return _wordsTurn('出了点问题。');
  }

  List<Map<String, Object?>> _answer(int index, Map<String, Object?> body) {
    if (_isMaintenance(body)) {
      maintenance.add(body);
      return _wordsTurn('这轮没有新增记忆。');
    }
    ordinary.add(body);
    final turn = _turnOf(body);
    if (turn.said != said) return _problem('unexpected words: ${turn.said}');
    if (turn.round == 0) {
      if (issuedId != null) return _problem('planned the task again');
      issuedId = 'offline-task-$index';
      return _toolTurn(issuedId!, call.$1, call.$2);
    }
    final blocks = _toolResults2(body);
    if (turn.round != 1 || blocks.length != 1 || blocks.single['tool_use_id'] != issuedId) {
      return _problem('no single original tool result in round ${turn.round}');
    }
    final result = _toolResults(body).single;
    if (failureLine != null) {
      if (result['accepted'] != false || result['code'] != 'selection_cancelled' || blocks.single['is_error'] != true) {
        return _problem('not the actual selection failure: $result');
      }
      return _wordsTurn(failureLine!);
    }
    if (result['accepted'] != true || blocks.single['is_error'] == true) {
      return _problem('original task not accepted: $result');
    }
    // Accepted only: the offline computer has not run anything yet.
    return _wordsTurn('嗯。');
  }

  /// The one tool result her second round carried back.
  Map<String, Object?> get result => _toolResults(ordinary.last).single;

  /// Exactly one planned call and one continuation with its real result: the
  /// offline tool was offered (notes_to_todo is not, it needs a live Host),
  /// and the result is the real failure or acceptance.
  void expectTurn() {
    expect(problems, isEmpty);
    expect(ordinary, hasLength(2));
    final offered = [for (final tool in ordinary.first['tools']! as List) (tool as Map)['name']! as String];
    expect(offered, contains(call.$1));
    expect(offered, isNot(contains('notes_to_todo')));
    final block = _toolResults2(ordinary.last).single;
    expect(block['tool_use_id'], issuedId);
    if (failureLine != null) {
      expect(block['is_error'], isTrue);
      expect(result['accepted'], isFalse);
      expect(result['code'], 'selection_cancelled');
    } else {
      expect(block['is_error'], isNot(true));
      expect(result['accepted'], isTrue);
    }
  }
}

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
      // The pack check is real file work: wait for the setup screen itself.
      await _until2(
        tester,
        () => find.text('把她接回家').evaluate().length == 1 && find.text('导入素材包').evaluate().length == 1,
      );
      expect(find.text('把她接回家'), findsOneWidget);
      expect(find.text('导入素材包'), findsOneWidget);
    });

    testWidgets('assistant waits for the foreground and keeps typing available after microphone denial', (
      tester,
    ) async {
      const channel = MethodChannel('dsh/voice');
      var permissionRequests = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'capabilities') return {'recognizer': true};
        if (call.method == 'requestPermission') {
          permissionRequests++;
          return 'denied';
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      final lifecycle = tester.binding.lifecycleState;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      if (lifecycle != null) addTearDown(() => tester.binding.handleAppLifecycleStateChanged(lifecycle));
      CompanionStageEvents? stageEvents;
      await tester.pumpWidget(
        _app(
          CompanionPage(
            storeOverride: installedStore(),
            assistantEntry: const CompanionAssistantEntry(page: 'Train arrives at 9:30'),
            stageBuilder: (_, events) {
              stageEvents = events;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      final stage = await _stageUp(tester, () => stageEvents);
      stage.onReady();
      await tester.pump();
      expect(permissionRequests, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(permissionRequests, 1);
      expect(find.byType(EditableText), findsOneWidget);
      final attachment = tester.widget<InputChip>(find.byType(InputChip));
      expect(find.text('已附当前页面文字'), findsOneWidget);
      attachment.onDeleted!();
      await tester.pump();
      expect(find.text('已附当前页面文字'), findsNothing);
      await tester.pumpWidget(_app(const SizedBox()));
      await _settle(tester);
    });

    testWidgets('back from a phone task asked in her room: what covers it closes, the same room stays', (tester) async {
      CompanionStageEvents? stageEvents;
      await tester.pumpWidget(_app(const Scaffold(body: SystemEntryHost())));
      final home = tester.element(find.byType(SystemEntryHost));
      unawaited(
        Navigator.of(home).push(
          MaterialPageRoute<void>(
            builder: (_) => CompanionPage(
              storeOverride: installedStore(),
              stageBuilder: (_, events) {
                stageEvents = events;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      final stage = await _stageUp(tester, () => stageEvents);
      stage.onReady();
      await _until2(tester, () => find.byType(EditableText).evaluate().isNotEmpty);
      await tester.enterText(find.byType(EditableText), '还没发的话');
      final room = tester.state(find.byType(CompanionPage));
      // A page she opened over her room, as her tasks or her own page are.
      unawaited(
        Navigator.of(tester.element(find.byType(CompanionPage))).push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('她的任务'))),
        ),
      );
      await _settle(tester);
      expect(find.text('她的任务'), findsOneWidget);

      ProviderScope.containerOf(home).read(launcherBridgeProvider).add(const OpenCompanionEntry(room: true));
      await _settle(tester);
      expect(find.text('她的任务'), findsNothing);
      expect(tester.state(find.byType(CompanionPage)), same(room));
      expect(ModalRoute.of(tester.element(find.byType(CompanionPage)))!.isCurrent, isTrue);
      expect(find.text('还没发的话'), findsOneWidget);

      // Already in front: nothing moves, no second room.
      ProviderScope.containerOf(home).read(launcherBridgeProvider).add(const OpenCompanionEntry(room: true));
      await _settle(tester);
      expect(find.byType(CompanionPage), findsOneWidget);
      expect(tester.state(find.byType(CompanionPage)), same(room));
      await tester.pumpWidget(_app(const SizedBox()));
      await _settle(tester);
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
      // Her greeting waits on the real memory and keeper reads: wait for it.
      await _until2(tester, () => find.text('你好呀，我是鲸鱼娘。以后就住在这里了，请多指教。').evaluate().length == 1);
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

    testWidgets('the section: her room, what she remembers and her own page share one bar', (tester) async {
      SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
      CompanionStageEvents? stageEvents;
      late VoidCallback openAssistant;
      late Database database;
      await tester.pumpWidget(
        _app(
          Consumer(
            builder: (context, ref, child) {
              openAssistant = () => unawaited(
                openCompanionAssistant(context, ref, const CompanionAssistantEntry(page: 'Train arrives at 9:30')),
              );
              return child!;
            },
            child: CompanionPage(
              storeOverride: installedStore(),
              sections: true,
              stageBuilder: (controller, events) {
                stageEvents = events;
                return const SizedBox.expand();
              },
            ),
          ),
          extra: [
            companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) {
              database = sqlite3.open('${root.path}/memory.sqlite');
              final memory = CompanionMemoryOwner(
                CompanionMemoryStore(database, nowMilliseconds: () => DateTime.now().millisecondsSinceEpoch),
                CompanionLocal.at(root),
              );
              ref.onDispose(memory.dispose);
              return memory;
            }),
          ],
        ),
      );
      await _stageUp(tester, () => stageEvents);
      stageEvents!.onReady();
      // The bar comes with her room, once she's there.
      await _until2(tester, () => find.text('和鲸鱼娘说点什么').evaluate().isNotEmpty);
      await _settle(tester);
      // The bar has her page, so the room keeps no ⋯ of its own.
      expect(find.byIcon(AppIcons.more), findsNothing);

      await tester.tap(find.text('记忆'));
      await _until2(tester, () => find.byType(CompanionMemoryPage).evaluate().isNotEmpty);
      expect(find.text('还没有记下什么'), findsOneWidget);

      // Her memory editor also opens the keyboard over the stored cards.
      await tester.tap(find.byTooltip('添加'));
      await _settle(tester);
      expect(find.byType(TextFormField), findsOneWidget);
      final rebuilt = <Type>[];
      addTearDown(tester.view.resetViewInsets);
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is CompanionMemoryPage) rebuilt.add(element.widget.runtimeType);
      };
      for (final inset in [120.0, 240.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump();
      }
      debugOnRebuildDirtyWidget = null;
      expect(rebuilt, isEmpty);
      await tester.enterText(find.byType(TextFormField), '周末喜欢去海边散步');
      await tester.tap(find.text('保存'));
      tester.view.resetViewInsets();
      await _until2(
        tester,
        () => find.byType(AlertDialog).evaluate().isEmpty && find.text('周末喜欢去海边散步').evaluate().isNotEmpty,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('还没有记下什么'), findsNothing);
      // The test has no home screen widget to clear: its notice goes first.
      await _until2(tester, () => find.byType(SnackBar).evaluate().isEmpty);

      await tester.tap(find.text('交代'));
      await _until2(tester, () => find.byType(CompanionTasksPage).evaluate().isNotEmpty);

      await tester.tap(find.text('她').last);
      await _until2(tester, () => find.text('她多主动').evaluate().isNotEmpty);
      expect(find.text('她的声音'), findsOneWidget);

      openAssistant();
      await _settle(tester);
      expect(find.byType(CompanionPage, skipOffstage: false), findsOneWidget);
      expect(find.text('已附当前页面文字'), findsOneWidget);
      expect(find.text('和鲸鱼娘说点什么'), findsOneWidget);

      // The keyboard moves her room, and anything of hers (each update of a
      // reply too) builds the page again; the pages kept behind it (which
      // query the store as they build) don't build again.
      rebuilt.clear();
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget case CompanionPage() || CompanionMemoryPage() || CompanionTasksPage()) {
          rebuilt.add(element.widget.runtimeType);
        }
      };
      for (final inset in [120.0, 240.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump();
      }
      // Her page, seen and now hidden, is not made again: it reads the whole phone log.
      var messageReads = 0;
      database.trace = SqliteTraceCallback((event) {
        final sql = event is SqliteTraceStatement ? event.sql ?? '' : '';
        if (sql.contains('FROM memory_messages m JOIN') && !sql.contains('WHERE')) messageReads++;
        return 0;
      });
      stageEvents!.onMood('sleeping');
      await tester.pump();
      database.trace = null;
      debugOnRebuildDirtyWidget = null;
      expect(rebuilt, [CompanionPage]);
      expect(messageReads, 0);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a key builds the composer, not her stage; the gate still hears the room is busy', (tester) async {
      SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
      final clock = _Clock();
      final initiative = _RecordingInitiative(clock.call);
      addTearDown(initiative.dispose);

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
      // Page 挂载后才会连接记忆并开始恢复 owner。
      await settleMixed(tester, initiative.ready);
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
      // Her arrival first opens the real memory store, then reads the keeper.
      await _until2(tester, () => phone.events.isNotEmpty);
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
      // One of her three ordinary hug lines: the fonder one waits for the Close tier.
      expect(find.textContaining(RegExp('抱抱|好安心|再抱一会儿')), findsOneWidget);
      expect(find.textContaining('抱紧一点'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a step closer while you are here: a hop and a word, once; the menu shows where you are', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
      _resumeApp(tester);
      // Affinity v2 (A2): steps are settled per completed day from real facts,
      // never from the keeper's activity closeness. Five earlier days with her
      // (an hour and eight lines each) settle to 25758 milli, still step 0.
      final pack = installedStore();
      final clock = _Clock()
        ..wall = DateTime.utc(2026, 11, 1, 10).millisecondsSinceEpoch
        ..mono = 0
        ..offset = 0;
      final memory = _ReceiptMemory(
        CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => clock.wall),
        CompanionLocal.at(root),
        nowMilliseconds: () => clock.wall,
      );
      addTearDown(memory.dispose);
      final key = await settleMixed(tester, pack.characterKey());
      await settleMixed(tester, memory.migrateLocal());
      final role = memory.store.ensureCompanionCharacter(sourceKey: key!)['id']! as String;
      for (var day = 1; day <= 5; day++) {
        final start = DateTime.utc(2026, 11, day, 10).millisecondsSinceEpoch;
        for (var turn = 0; turn < 8; turn++) {
          clock.wall = start + turn * 60000;
          final source = memory.store.submitMessage(
            id: 'hop-$day-$turn',
            sessionId: 'light:earlier-days',
            text: '今天陪你聊了第 ${turn + 1} 件小事。',
            saidAtUtc: clock.wall,
            offsetMinutes: clock.offset,
            characterId: role,
          );
          memory.store.recordCompanionInteraction(
            characterId: role,
            eventId: source['id']! as String,
            kind: 'chat',
            sourceId: source['id']! as String,
            atMs: clock.wall,
            offsetMinutes: clock.offset,
          );
        }
        clock.wall = start + const Duration(hours: 1).inMilliseconds;
        memory.store.recordCompanionPresence(
          characterId: role,
          segmentId: 'hop-presence-$day',
          startedAtMs: start,
          elapsedMs: const Duration(hours: 1).inMilliseconds,
          offsetMinutes: clock.offset,
        );
      }
      memory.store.settleCompanionAffinity(nowMs: clock.wall, offsetMinutes: clock.offset);
      MemoryRow affinity() => memory.store.companionAffinity(characterId: role)!;
      expect(affinity()['score_milli'], 25758);
      expect(affinity()['tier'], 0);
      expect(affinity()['settled_through_day'], '2026-11-04');

      final phone = FakePhoneKeeper(state: FakePhoneKeeper.snapshotOf(closeness: 0.025));
      final commands = <(String, Map<String, Object?>)>[];
      Iterable<(String, Map<String, Object?>)> hops() =>
          commands.where((c) => c.$1 == 'action' && c.$2['name'] == 'hop');
      CompanionStageEvents? stageEvents;
      await tester.pumpWidget(
        _app(
          CompanionPage(
            storeOverride: pack,
            stageBuilder: (controller, events) {
              stageEvents = events;
              return const SizedBox.expand();
            },
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
          ),
          phone: phone,
          extra: [
            companionInitiativeClockProvider.overrideWithValue(clock.call),
            companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory),
          ],
        ),
      );
      (await _stageUp(tester, () => stageEvents)).onReady();
      await _until2(tester, () => phone.events.contains('visit'));
      // Arriving already at a step is not news.
      expect(hops(), isEmpty);
      await tester.pump(const Duration(seconds: 8));

      // A pat today counts toward today, which is still open: no step yet,
      // whatever the keeper's activity closeness says.
      phone.closenessAfter = 0.035;
      stageEvents!.onTouch('head', 'pat');
      await _until2(tester, () => phone.events.contains('pet'));
      await _settle(tester);
      expect(affinity()['score_milli'], 25758);
      expect(hops(), isEmpty);

      // Still here past midnight: her next look at the room (once a minute)
      // settles the day that just ended (25758 + 6880 + the pat's 100 = 32738,
      // step 1). Step by seconds so her word is still up when it comes.
      final midnight = DateTime.utc(2026, 11, 6, 0, 5).millisecondsSinceEpoch;
      clock
        ..mono += midnight - clock.wall
        ..wall = midnight;
      for (var i = 0; i < 70 && hops().isEmpty; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pump();
      expect(affinity()['settled_through_day'], '2026-11-05');
      expect(affinity()['score_milli'], 32738);
      expect(affinity()['tier'], 1);
      expect(hops(), hasLength(1));
      expect(find.text('好像……没那么紧张了。'), findsOneWidget);

      // Once: the same day settled again, and the room looked at again.
      expect(memory.store.settleCompanionAffinity(nowMs: clock.wall, offsetMinutes: clock.offset), isEmpty);
      memory.changed();
      await tester.pump(const Duration(minutes: 1));
      expect(hops(), hasLength(1));

      await tester.pump(const Duration(seconds: 8));
      await tester.tap(find.byIcon(AppIcons.more));
      await tester.pumpAndSettle();
      expect(find.text('你们的关系'), findsOneWidget);
      expect(find.text('熟悉'), findsOneWidget);
      expect(hops(), hasLength(1));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
      await _drained(tester, memory);
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
      // Her new persona also gets her own lines written once; the chat is what's checked here.
      Iterable<Map<String, Object?>> chat() =>
          asked.where((r) => !(r['system']! as String).startsWith('你在为一个陪伴角色写'));
      for (var i = 0; i < 20 && chat().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final system = chat().single['system']! as String;
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
      final pack = installedStore();
      final clock = _Clock();
      final db = sqlite3.open('${root.path}/memory.sqlite');
      final memory = _RoomMemory2(CompanionMemoryStore(db, nowMilliseconds: () => clock.wall), CompanionLocal.at(root));
      addTearDown(memory.dispose);
      final key = await settleMixed(tester, pack.characterKey());
      await settleMixed(tester, memory.migrateLocal());
      final role = memory.store.ensureCompanionCharacter(sourceKey: key!)['id']! as String;
      final phone = FakePhoneKeeper();
      List<String> interactions() => db
          .select(
            "SELECT kind FROM memory_affinity_events WHERE character_id=? AND kind IN ('snack','play') ORDER BY kind",
            [role],
          )
          .map((row) => row['kind']! as String)
          .toList();
      final commands = <(String, Map<String, Object?>)>[];
      CompanionStageEvents? stageEvents;
      await tester.pumpWidget(
        _app(
          CompanionPage(
            storeOverride: pack,
            stageBuilder: (controller, events) {
              stageEvents = events;
              return const SizedBox.expand();
            },
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
          ),
          phone: phone,
          extra: [
            companionInitiativeClockProvider.overrideWithValue(clock.call),
            companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory),
          ],
        ),
      );
      await _stageUp(tester, () => stageEvents);
      stageEvents!.onReady();
      await _until2(tester, () => memory.room != null);
      await _settle(tester);
      // The greeting first; then the hint for her things.
      await tester.pump(const Duration(seconds: 8));
      await _settle(tester);
      expect(find.text('点点贝壳、泡泡和软垫，点心还能拖到她嘴边'), findsOneWidget);

      expect(interactions(), isEmpty);
      commands.clear();
      stageEvents!.onObject('snack');
      await tester.pump(const Duration(milliseconds: 100));
      final activity = commands.where((c) => c.$1 == 'activity').single.$2;
      expect(activity['name'], 'snack');
      expect(activity['remainingMs'], 45000);
      expect(interactions(), ['snack']);
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

      // These are real Page actions with memory ready but no activity snapshot.
      stageEvents!.onObject('play');
      await tester.pump(const Duration(milliseconds: 100));
      expect(interactions(), ['play', 'snack']);
      stageEvents!.onObject('rest');
      await tester.pump(const Duration(milliseconds: 100));
      expect(interactions(), ['play', 'snack']);
      expect(phone.events, isEmpty, reason: 'no activity write is fabricated without a snapshot');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
      await _drained(tester, memory);
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
        Override? connectionOverride,
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
            connectionOverride: connectionOverride,
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

      for (final sameWordsFromWake in [false, true]) {
        testWidgets('a completed hidden reply is presented only by its actual bubble: $sameWordsFromWake', (
          tester,
        ) async {
          _resumeApp(tester);
          final clock = _Clock()..wall = DateTime.now().toUtc().millisecondsSinceEpoch;
          final db = sqlite3.open('${root.path}/memory.sqlite');
          final memory = _ReceiptMemory(
            CompanionMemoryStore(db, nowMilliseconds: () => clock.wall),
            CompanionLocal.at(root),
            nowMilliseconds: () => clock.wall,
          );
          final reached = Completer<void>();
          final release = Completer<void>();
          final posts = <Map<String, Object?>>[];
          const markOnly = '[表情:开心]';
          const earlyWords = '第一轮：先理清线索。';
          final lastWords = [for (var i = 1; i <= 16; i++) '后续第$i行：这段文字来自最后一轮模型回复。', '好了。'].join('\n');
          var words = '$earlyWords\n$lastWords';
          var chatRounds = 0;
          CompanionStageEvents? stageEvents;
          final client = MockClient.streaming((request, bytes) async {
            final body = jsonDecode(await bytes.bytesToString()) as Map<String, Object?>;
            posts.add(body);
            if (_isChat2(body)) {
              final round = chatRounds++;
              if (!reached.isCompleted) reached.complete();
              await release.future;
              final response = !sameWordsFromWake && round < 2
                  ? _reply2(
                      words: round == 0 ? markOnly : earlyWords,
                      calls: [
                        ('visible-$round', 'recall', {'query': '线索'}),
                      ],
                    )
                  : _reply2(words: sameWordsFromWake ? words : lastWords);
              return http.StreamedResponse(
                Stream.value(response.bodyBytes),
                response.statusCode,
                headers: response.headers,
              );
            }
            return http.StreamedResponse(Stream.value(utf8.encode(_messageEvents(_wordsTurn('')))), 200);
          });
          addTearDown(() async {
            if (!release.isCompleted) release.complete();
            await _drained(tester, memory);
            await tester.pumpWidget(const SizedBox());
            memory.dispose();
            await tester.pump();
            client.close();
          });
          await openLight(
            tester,
            apiKey: 'sk-test',
            client: client,
            events: (events) => stageEvents = events,
            extra: [
              companionInitiativeClockProvider.overrideWithValue(clock.call),
              companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory),
            ],
          );
          expect(await memoryOf(tester), same(memory));
          final page = tester.element(find.byType(CompanionPage));
          final container = ProviderScope.containerOf(page);
          final agent = container.read(companionAgentProvider);
          final navigator = Navigator.of(page);
          final memoryTitle = L10n.of(page).companionMemoryTitle;
          if (sameWordsFromWake) words = L10n.of(page).companionWake;
          // Keep independent invitations out of this reply-presentation scenario.
          await settleMixed(tester, container.read(companionInitiativeEnabledProvider.notifier).set(false));
          expect(container.read(companionInitiativeEnabledProvider) ?? false, isFalse);
          var agentChanges = 0;
          var memoryChanges = 0;
          void changed() => agentChanges++;
          void memoryChanged() => memoryChanges++;
          agent.addListener(changed);
          memory.addListener(memoryChanged);
          addTearDown(() => agent.removeListener(changed));
          addTearDown(() => memory.removeListener(memoryChanged));

          await tester.enterText(find.byType(TextField), '等我看一下记忆，再回来听你说。');
          await tester.pump();
          await tester.tap(find.byIcon(AppIcons.send).last);
          await settleMixed(tester, reached.future);
          // Use the real room's menu and read-only memory route. The same Page,
          // Agent and SQLite owner remain attached underneath it.
          await tester.tap(find.byIcon(AppIcons.more));
          await _notesVisible(tester, find.text(memoryTitle));
          await _settle(tester);
          // The real menu scrolls on a short screen; existence is not a hit target.
          await tester.ensureVisible(find.text(memoryTitle));
          await _notesVisible(tester, find.text(memoryTitle).hitTestable());
          expect(find.text(memoryTitle).hitTestable(), findsOneWidget);
          await tester.tap(find.text(memoryTitle));
          await _notesVisible(tester, find.byType(CompanionMemoryPage));
          await tester.pump(const Duration(milliseconds: 400));
          await _settle(tester);
          expect(ModalRoute.of(page)!.isCurrent, isFalse);
          expect(TickerMode.valuesOf(page).enabled, isFalse);

          release.complete();
          await _drained(tester, memory);
          // The worker can notify after the Agent's retained turn has settled.
          // Finish that work and its frames while the room is still hidden.
          await _until2(
            tester,
            () => !memory.working && memory.store.requests().every((r) => r['state'] == 'finished'),
          );
          await _drained(tester, memory);
          await _settle(tester);
          expect(agent.running, isFalse);
          expect(agent.text, sameWordsFromWake ? words : '$markOnly\n$words');
          final assistants = memory.store.messages().where((row) => row['role'] == 'assistant').toList();
          expect(assistants, hasLength(sameWordsFromWake ? 1 : 3));
          final assistant = assistants.singleWhere((row) => row['text'] == (sameWordsFromWake ? words : lastWords));
          if (!sameWordsFromWake) {
            expect(assistants.where((row) => row['text'] == markOnly), hasLength(1));
            expect(assistants.where((row) => row['text'] == earlyWords), hasLength(1));
            for (final body in posts.where(_isChat2).skip(1)) {
              final results = _toolResults2(body);
              expect(results, hasLength(1));
              expect(results.single['is_error'], isNot(true));
              expect(_toolResult2(body)['applied'], isTrue);
            }
          }
          // The Agent saves assistant sources with its real wall clock. Keep
          // the existing fake presentation clock at or after that real source,
          // and complete any changed-day settlement under the hidden route.
          clock.wall = assistants.map((row) => row['said_at_utc']! as int).reduce((a, b) => a > b ? a : b) + 1;
          memory.changed();
          await _drained(tester, memory);
          await _settle(tester);
          expect(memory.working, isFalse);
          expect(memory.store.requests().every((r) => r['state'] == 'finished'), isTrue);
          expect(memory.store.archive['widget_clear_pending'], 0);
          if (sameWordsFromWake) {
            // A real stage wake replaces the hidden model bubble with identical
            // words. Text equality must not give that other line its source ID.
            stageEvents!.onWake();
            await _settle(tester);
          }
          expect(posts.where(_isChat2), hasLength(sameWordsFromWake ? 1 : 3));
          expect(db.select('SELECT * FROM memory_affinity_presentations'), isEmpty);
          expect(find.text(words), findsNothing);
          final changesBeforeReturn = agentChanges;
          final memoryChangesBeforeReturn = memoryChanges;
          final requestsBeforeReturn = memory.store.requests();
          final postsBeforeReturn = posts.length;
          final receiptsBeforeReturn = memory.receipts.length;
          final messagesBeforeReturn = memory.store.messages();

          navigator.pop();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
          expect(find.text(words), findsOneWidget);
          expect(agentChanges, changesBeforeReturn, reason: 'returning must not rely on another Agent notification');
          expect(memoryChanges, memoryChangesBeforeReturn);
          var shown = db.select('SELECT * FROM memory_affinity_presentations');
          expect(shown, hasLength(sameWordsFromWake ? 0 : 1));
          if (!sameWordsFromWake) {
            expect(shown.single['id'], 'assistant:${assistant['id']}');
            expect(shown.single['assistant_source_id'], assistant['id']);
            expect(shown.single['kind'], 'assistant');
            expect(shown.single['presented_at_ms'], clock.wall);

            final scroll = tester
                .state<ScrollableState>(
                  find.descendant(of: find.byType(CompanionSpeech), matching: find.byType(Scrollable)),
                )
                .position;
            expect(scroll.pixels, 0, reason: 'the unchanged reverse bubble starts at its newest lines');
            expect(scroll.maxScrollExtent, greaterThan(0));
            final early = assistants.singleWhere((row) => row['text'] == earlyWords);
            final mark = assistants.singleWhere((row) => row['text'] == markOnly);
            expect(shown.any((row) => row['assistant_source_id'] == early['id']), isFalse);
            expect(shown.any((row) => row['assistant_source_id'] == mark['id']), isFalse);

            // Scroll the actual existing bubble to its oldest lines. No new
            // Agent/Owner notification or model round makes this source seen.
            scroll.jumpTo(scroll.maxScrollExtent);
            await tester.pump();
            await tester.pump();
            shown = db.select('SELECT * FROM memory_affinity_presentations');
            expect(shown.map((row) => row['assistant_source_id']), unorderedEquals([assistant['id'], early['id']]));
            expect(shown.any((row) => row['assistant_source_id'] == mark['id']), isFalse);
            expect(agentChanges, changesBeforeReturn);
            expect(memoryChanges, memoryChangesBeforeReturn);
            scroll.jumpTo(0);
            await tester.pump();
            expect(db.select('SELECT * FROM memory_affinity_presentations'), shown);
          }

          // Another actual frame and a pause/resume keep the same durable fact;
          // they do not submit another turn or manufacture a new model receipt.
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          await tester.pump();
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await tester.pump();
          await tester.pump();
          expect(db.select('SELECT * FROM memory_affinity_presentations'), shown);
          expect(memory.store.messages(), messagesBeforeReturn);
          expect(memory.store.requests(), requestsBeforeReturn);
          expect(memory.receipts, hasLength(receiptsBeforeReturn));
          expect(posts, hasLength(postsBeforeReturn));
        });
      }

      for (final scenario in [
        'default',
        'full-offline',
        'selected',
        'query-empty',
        'source-failure',
        'targets-route',
        'scope-route',
        'queued-handoff-route',
        'dispatched-cancel',
      ]) {
        testWidgets('G actual Page map handoff boundary: $scenario', (tester) async {
          final before = tester.binding.lifecycleState;
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          addTearDown(() {
            if (before != null) {
              tester.binding.handleAppLifecycleStateChanged(before);
            } else {
              tester.binding.resetInternalState();
            }
          });
          const now = 1795219200000;
          const address = ' 文华路 18 号东门 & A座（入口😀）；不走西门 ';
          const raw = '在地图打开“$address”，我自己看路线；我午后练长笛';
          final db = sqlite3.open('${root.path}/memory.sqlite');
          final memory = _ReceiptMemory(
            CompanionMemoryStore(db, nowMilliseconds: () => now),
            CompanionLocal.at(root),
            nowMilliseconds: () => now,
          );
          final peer = MapPlatformPeer(db, memory.store);
          final reached = Completer<void>();
          final release = Completer<void>();
          final releaseNativeClose = Completer<void>();
          Future<void>? handling;
          // Her model asks for the map with the literal address; a later
          // cancel reads the original task first, then cancels that revision.
          final model = _AgentModel.script(
            (said) => said == raw
                ? [
                    ('map_open', {'operation': 'create', 'address': address}),
                  ]
                : said == '取消打开地图'
                ? [
                    ('task_status', <String, Object?>{}),
                    (
                      'map_open',
                      (List<Map<String, Object?>> results) {
                        final task = (results.single['tasks']! as List).single as Map;
                        return <String, Object?>{
                          'operation': 'cancel',
                          'taskId': task['task_id'],
                          'expectedTaskRev': task['task_rev'],
                        };
                      },
                    ),
                  ]
                : const [],
          );
          var simulatedPhysicalCalls = 0;
          final sourceCommittedBeforePlatform = <bool>[];
          int? queuedScopeClosed;
          if (scenario == 'selected') {
            peer.targets = {
              'kind': 'choice',
              'targets': [MapPlatformPeer.target],
            };
          } else if (scenario == 'query-empty') {
            peer.targets = {'kind': 'unknown', 'targets': []};
          }
          peer.before = (call) async {
            if (call.method == 'capabilities' || call.method == 'targets') {
              sourceCommittedBeforePlatform.add(memory.store.messages().any((row) => row['role'] == 'user'));
            }
            if ((scenario == 'targets-route' && call.method == 'targets') ||
                (scenario == 'scope-route' && call.method == 'openScope')) {
              reached.complete();
              await release.future;
            }
            if (scenario == 'queued-handoff-route' && call.method == 'closeScope') {
              // Hold the asynchronous native close, so only the synchronous
              // owning-store invalidation can have closed this scope row.
              await releaseNativeClose.future;
            }
          };
          peer.onHandoff = (task) async {
            if (scenario == 'queued-handoff-route') {
              reached.complete();
              await release.future;
              final scope = peer.calls.lastWhere((call) => call.method == 'handoff').arguments as Map<Object?, Object?>;
              queuedScopeClosed =
                  db.select('SELECT closed FROM companion_map_scopes WHERE scope_id=?', [
                        scope['scopeId'],
                      ]).single['closed']!
                      as int;
              peer.blocked(task, 'not-started-at-closed-scope');
              return;
            }
            final attempt = peer.claim(task);
            simulatedPhysicalCalls++;
            // Native commits the physical call and its returned receipt in
            // one write transaction; only the channel ACK may arrive later.
            peer.returned(task, attempt, chooser: scenario == 'query-empty');
            if (scenario == 'dispatched-cancel') {
              reached.complete();
              await release.future;
            }
            if (!reached.isCompleted) {
              reached.complete();
            }
          };
          addTearDown(() async {
            if (!release.isCompleted) {
              release.complete();
            }
            if (!releaseNativeClose.isCompleted) {
              releaseNativeClose.complete();
            }
            if (handling != null) {
              await settleMixed(tester, handling);
            }
            await tester.pumpWidget(const SizedBox());
            memory.dispose();
            await tester.pump();
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(MapPlatformPeer.channel, null);
          });
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(MapPlatformPeer.channel, peer.handle);
          final commands = await openLight(
            tester,
            apiKey: 'sk-test',
            client: model.client,
            extra: [
              companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory),
              if (scenario == 'full-offline') companionModeProvider.overrideWith(_MapsFullMode.new),
            ],
          );
          expect(await memoryOf(tester), same(memory));
          await settleMixed(tester, memory.migrateLocal());
          if (scenario == 'source-failure') {
            db.execute(
              "CREATE TRIGGER reject_map_source BEFORE INSERT ON memory_events BEGIN SELECT RAISE(ABORT,'fixture'); END",
            );
          }
          await tester.enterText(find.byType(TextField), raw);
          await tester.pump();
          await tester.tap(find.byIcon(AppIcons.send).last);
          if (scenario == 'source-failure') {
            // The source is committed before any model round now, so a failed
            // commit is the ordinary "not sent" line, with the draft kept.
            await _notesVisible(tester, find.text('这句话没送出去，要不要再说一次？'));
            expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
            expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, raw);
            expect(memory.store.messages(), isEmpty);
            expect(memory.store.tasks(), isEmpty);
            expect(peer.calls, isEmpty);
            expect(model.requests, isEmpty);
            return;
          }
          if (scenario == 'selected') {
            await _notesVisible(tester, find.byType(SimpleDialog));
            expect(memory.store.tasks(), isEmpty);
            expect(peer.calls.where((call) => call.method == 'openScope'), isEmpty);
            await tester.tap(find.text('实际候选地图'));
          }
          await settleMixed(tester, reached.future);
          handling = memory.lastReceipt;
          final original = memory.store.messages().singleWhere((row) => row['role'] == 'user');
          expect(original['text'], raw);
          expect(original['scope'], 'real');
          final accepted = memory.store.tasks();
          expect(accepted, hasLength(scenario == 'targets-route' ? 0 : 1));
          commands.clear();
          final route = scenario.endsWith('-route');
          NavigatorState? navigator;
          if (route) {
            navigator = Navigator.of(tester.element(find.byType(CompanionPage)));
            unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('与地图无关的页面')))));
            await tester.pumpAndSettle();
            if (scenario == 'queued-handoff-route') {
              final scope = peer.calls.lastWhere((call) => call.method == 'handoff').arguments as Map<Object?, Object?>;
              expect(
                db.select('SELECT closed FROM companion_map_scopes WHERE scope_id=?', [
                  scope['scopeId'],
                ]).single['closed'],
                1,
              );
              expect(releaseNativeClose.isCompleted, isFalse);
              final methods = peer.calls.map((call) => call.method).toList();
              expect(methods.indexOf('handoff'), lessThan(methods.indexOf('closeScope')));
            }
            release.complete();
            if (scenario == 'queued-handoff-route') {
              releaseNativeClose.complete();
            }
          } else if (scenario == 'dispatched-cancel') {
            final changed = Completer<void>();
            final id = accepted.single['task_id']! as String;
            expect(memory.store.mapTask(id)!['state'], 'done');
            expect(memory.store.taskReceipts(id).where((row) => row['event_kind'] == 'returned').single['task_rev'], 1);
            void onChanged() {
              if (!changed.isCompleted && memory.store.mapTask(id)!['cancel_requested'] == 1) {
                changed.complete();
              }
            }

            memory.addListener(onChanged);
            // The earlier turn is still handing the address over; whatever is
            // typed can go (the model, not the text, decides it is a cancel).
            await tester.enterText(find.byType(TextField), '取消打开地图');
            await tester.pump();
            expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
            expect(release.isCompleted, isFalse);
            await tester.tap(find.byIcon(AppIcons.send).last);
            await settleMixed(tester, changed.future);
            memory.removeListener(onChanged);
            await settleMixed(tester, memory.lastReceipt);
            expect(memory.store.mapTask(id)!['state'], 'cancelled');
            release.complete();
          }
          await _drained(tester, memory);
          expect(sourceCommittedBeforePlatform, isNotEmpty);
          expect(
            sourceCommittedBeforePlatform,
            everyElement(isTrue),
            reason: 'The actual source transaction must commit before platform work',
          );
          if (route) {
            expect(simulatedPhysicalCalls, 0);
            expect(
              peer.calls.where((call) => call.method == 'handoff'),
              hasLength(scenario == 'queued-handoff-route' ? 1 : 0),
            );
            if (scenario == 'scope-route') {
              expect(db.select('SELECT closed FROM companion_map_scopes').single['closed'], 1);
            }
            if (scenario == 'queued-handoff-route') {
              expect(queuedScopeClosed, 1, reason: 'The queued native boundary observes the committed route closure');
            }
            navigator!.pop();
            await tester.pumpAndSettle();
            expect(find.text('查看地址'), findsNothing);
            expect(find.text('地址已交给地图打开。'), findsNothing);
            expect(commands.where((command) => command.$1 == 'say' && jsonEncode(command.$2).contains('地图')), isEmpty);
          } else {
            final task = memory.store.mapTask(accepted.single['task_id']! as String)!;
            expect(task['address'], address);
            expect(task['source_message_id'], original['id']);
            expect(task['item_no'], 0);
            // Both modes share the phone loop and its one conversation: an
            // offline full room opens the map on the phone, in that chat.
            expect(task['room_mode'], 'light');
            expect(task['source_session_id'], memory.store.lightSessionId);
            expect(
              task['target_kind'],
              scenario == 'selected'
                  ? 'selected'
                  : scenario == 'query-empty'
                  ? 'choice'
                  : 'default',
            );
            expect(task['package_uid'], scenario == 'query-empty' ? null : 12001);
            expect(
              task['state'],
              scenario == 'dispatched-cancel'
                  ? 'cancelled'
                  : scenario == 'query-empty'
                  ? 'waiting'
                  : 'done',
            );
            expect(simulatedPhysicalCalls, 1);
            if (scenario == 'dispatched-cancel') {
              expect(task['task_rev'], 2);
              expect(
                memory.store
                    .taskReceipts(task['task_id']! as String)
                    .where((row) => row['event_kind'] == 'returned')
                    .single['task_rev'],
                1,
              );
              expect(find.text('地址已交给地图打开。'), findsNothing);
              expect(
                commands.where((command) => command.$1 == 'say' && jsonEncode(command.$2).contains('地址已交给地图打开')),
                isEmpty,
              );
            } else {
              expect(find.text('查看地址'), findsOneWidget);
              await tester.tap(find.text('查看地址'));
              await _notesVisible(tester, find.byType(CompanionTasksPage));
              expect(find.text(address), findsOneWidget);
              expect(
                find.text(scenario == 'query-empty' ? '刚才打开的是选择页面，还不能确定地址交给了哪个地图。' : '地址已交给地图打开。'),
                findsOneWidget,
              );
              expect(peer.calls.where((call) => call.method == 'handoff'), hasLength(1));
            }
          }
          // One round asks for the map; its result goes back for her words.
          // A cancel is its own turn: read the task, cancel it, then words.
          expect(model.offered.first, contains('map_open'));
          expect(model.chats, hasLength(scenario == 'dispatched-cancel' ? 4 : 2));
          if (!route && scenario != 'dispatched-cancel') expect(model.results.single['accepted'], isTrue);
          if (scenario == 'dispatched-cancel') {
            expect(model.results.last['accepted'], isTrue);
            expect((model.results.last['task']! as Map)['state'], 'cancelled');
          }
          // Product divergence for the two route scenarios, see [_routeMapPillGap].
        }, skip: _routeMapPillGap && (scenario == 'scope-route' || scenario == 'queued-handoff-route'));
      }

      for (final scenario in [
        'accepted',
        'source-failure',
        'leave-during-fourth-input',
        'cancel-during-fourth-input',
        'leave-after-acceptance',
      ]) {
        testWidgets('J actual Page binds four ordered receipts and output before durable acceptance: $scenario', (
          tester,
        ) async {
          _resumeApp(tester);
          const now = 1795219200000;
          const channel = MethodChannel('dsh/companion_reminders');
          final db = sqlite3.open('${root.path}/memory.sqlite');
          final memory = _ReceiptMemory(
            CompanionMemoryStore(db, nowMilliseconds: () => now),
            CompanionLocal.at(root),
            nowMilliseconds: () => now,
          );
          final peer = (await tester.runAsync(NotesPeer.open))!;
          peer.capability = receiptsCapability;
          final browsers = List.generate(5, (_) => Completer<void>());
          final bindings = List.generate(4, (_) => Completer<void>());
          final releaseFourth = Completer<void>();
          final postRead = Completer<void>();
          final releasePost = Completer<void>();
          final sourceAtBrowse = <List<MemoryRow>>[];
          final taskCountAtBind = <int>[];
          final possibleAtPost = <int?>[];
          final nativeCalls = <MethodCall>[];
          final inputs = receiptInputs();
          MemoryRow? snapshot;
          Future<void>? handling;
          var browserCount = 0;
          var inputCount = 0;
          // Her model asks for the sheet as said: four receipts, by eight
          // tonight, carrying on after she leaves. A cancel only reads tasks.
          final model = _AgentModel.script(
            (said) => said == receiptSpokenExample
                ? [_receiptsCall]
                : said == '取消整理票据'
                ? [('task_status', <String, Object?>{})]
                : const [],
            replies: const {'取消整理票据': '想停哪一张表？请到那件事里点取消。'},
          );
          var disposed = false;
          addTearDown(() async {
            if (!releaseFourth.isCompleted) {
              releaseFourth.complete();
            }
            if (!releasePost.isCompleted) {
              releasePost.complete();
            }
            await tester.pumpWidget(const SizedBox());
            if (handling != null) {
              await settleMixed(tester, handling);
            }
            if (!disposed) {
              memory.dispose();
            }
            await tester.pump();
            await tester.runAsync(peer.close);
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
          });
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
            nativeCalls.add(call);
            return switch (call.method) {
              'clock' => {'utcMs': now, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800},
              'resolve' => {
                'kind': 'unique',
                'moments': [
                  {'epochMs': DateTime.utc(2026, 11, 21, 12).millisecondsSinceEpoch, 'offsetSeconds': 28800},
                ],
              },
              'capabilities' => {'executorId': 'phone-original', 'exact': true, 'notifications': true},
              'recover' => {'recoveryQueued': true},
              _ => throw StateError('Unexpected receipt platform call ${call.method}'),
            };
          });
          peer.respond = (incoming, body) async {
            if (incoming.uri.path == '/api/directoryPicker/list') {
              final index = browserCount++;
              final path = index == 4 ? '/本人选的输出' : '/本人选的票据';
              sourceAtBrowse.add(memory.store.messages().where((row) => row['role'] == 'user').toList());
              await NotesPeer.json(incoming, {
                'type': 'server-response',
                'rpcId': body!['rpcId'],
                'result': {
                  'ok': true,
                  'value': {
                    'path': path,
                    'home': path,
                    'crumbs': [
                      {'name': index == 4 ? '本人选的输出' : '本人选的票据', 'path': path},
                    ],
                    'entries': <Object?>[],
                  },
                },
              });
              browsers[index].complete();
            } else if (incoming.uri.path == '$notesPath/folders') {
              await NotesPeer.json(
                incoming,
                body!['path'] == '/本人选的输出'
                    ? receiptOutput
                    : {
                        'v': 1,
                        'hostStoreId': 'original-store',
                        'folderRef': 'selected-inputs',
                        'displayPath': body['path'],
                      },
              );
            } else if (incoming.uri.path == '$notesPath/inputs') {
              final index = inputCount++;
              taskCountAtBind.add(memory.store.tasks().length);
              bindings[index].complete();
              if (index == 3) {
                await releaseFourth.future;
              }
              await NotesPeer.json(incoming, inputs[index]);
            } else if (incoming.method == 'POST' && incoming.uri.path == notesPath) {
              possibleAtPost.add(
                memory.store.hostTaskCommands(body!['taskId']! as String).single['possible_sent_at_ms'] as int?,
              );
              snapshot = notesSnapshot(body);
              postRead.complete();
              if (scenario == 'leave-after-acceptance') {
                await releasePost.future;
              }
              await NotesPeer.json(incoming, snapshot!, status: 201);
            } else if (incoming.method == 'GET' && incoming.uri.path == '$notesPath/${snapshot?['taskId']}') {
              await NotesPeer.json(incoming, snapshot!);
            } else {
              await NotesPeer.json(incoming, {
                'error': {'code': 'companion/task-not-found', 'message': 'No recorded receipt task'},
              }, status: 404);
            }
          };
          // The full room asks its Host for each model round.
          peer.hostModel.model = () => model.client;
          await openLight(
            tester,
            apiKey: 'sk-test',
            client: model.client,
            connection: HostConnection(client: peer.client, isLocal: false),
            extra: [..._hostRoom, companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
          );
          expect(await memoryOf(tester), same(memory));
          await settleMixed(tester, memory.migrateLocal());
          final sourceRoom = memory.store.lightSessionId;
          if (scenario == 'source-failure') {
            db.execute(
              "CREATE TRIGGER reject_receipts BEFORE INSERT ON memory_events "
              "BEGIN SELECT RAISE(ABORT,'fixture disk error'); END",
            );
          }
          await tester.enterText(find.byType(TextField), receiptSpokenExample);
          await tester.pump();
          await tester.tap(find.byIcon(AppIcons.send).last);
          if (scenario == 'source-failure') {
            // The source commits before any model round: the ordinary line.
            await _notesVisible(tester, find.text('这句话没送出去，要不要再说一次？'));
            expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
            expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, receiptSpokenExample);
            expect(memory.store.messages(), isEmpty);
            expect(memory.store.tasks(), isEmpty);
            expect(_taskCalls(peer), isEmpty);
            expect(model.requests, isEmpty);
            await tester.pumpWidget(const SizedBox());
            // The full room's real HttpClient keeps a 15-second idle timer.
            await tester.pump(const Duration(seconds: 16));
            return;
          }
          for (var index = 0; index < 4; index++) {
            // Wait for this input's own sheet: the previous one may still be closing.
            await _notesVisible(tester, find.text('第 ${index + 1} 份票据在哪个文件夹？'));
            handling ??= memory.lastReceipt;
            // Let the directory sheet finish sliding in before tapping an entry.
            await tester.pump(const Duration(milliseconds: 500));
            await tester.tap(find.text('主目录').last);
            await settleMixed(tester, browsers[index].future);
            // Wait on the whole set: `.last` of a not-yet-listed page throws.
            final choose = find.descendant(
              of: find.byType(DirectoryBrowserPage),
              matching: find.byWidgetPredicate((widget) => widget is FilledButton && widget.onPressed != null),
            );
            await _notesVisible(tester, choose);
            // The browser page is still sliding in; tap once it has landed.
            await tester.pump(const Duration(milliseconds: 500));
            await tester.tap(choose.last);
            await _notesVisible(tester, find.text('第 ${index + 1} 份票据的文件名'));
            final dialog = find.byType(AlertDialog);
            await tester.enterText(
              find.descendant(of: dialog, matching: find.byType(TextField)),
              inputs[index]['displayName']! as String,
            );
            await tester.tap(find.descendant(of: dialog, matching: find.text('保存')));
            await settleMixed(tester, bindings[index].future);
          }
          expect(taskCountAtBind, [0, 0, 0, 0]);
          expect(memory.store.tasks(), isEmpty);
          expect(peer.calls.where((call) => call.method == 'POST' && call.uri.path == notesPath), isEmpty);
          expect(sourceAtBrowse, hasLength(4));
          expect(
            sourceAtBrowse.every((rows) => rows.length == 1 && rows.single['text'] == receiptSpokenExample),
            isTrue,
          );
          expect(sourceAtBrowse.map((rows) => rows.single['id']).toSet(), hasLength(1));
          expect(sourceAtBrowse.map((rows) => rows.single['first_seq']).toSet(), hasLength(1));
          expect(peer.calls.where((call) => call.uri.path == '$notesPath/inputs').map((call) => call.body), [
            for (final input in inputs)
              {
                'v': 1,
                'hostStoreId': 'original-store',
                'folderRef': 'selected-inputs',
                'name': input['displayName'],
                'kind': 'host.receipts_to_sheet',
              },
          ]);
          if (scenario == 'leave-during-fourth-input') {
            await tester.pumpWidget(const SizedBox());
          } else if (scenario == 'cancel-during-fourth-input') {
            await _notesVisible(tester, find.byType(AlertDialog), absent: true);
            await tester.enterText(find.byType(TextField), '取消整理票据');
            await tester.pump();
            expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
            await tester.tap(find.byIcon(AppIcons.send).last);
            await _notesVisible(tester, find.text('想停哪一张表？请到那件事里点取消。'));
          }
          releaseFourth.complete();
          final accepted = scenario == 'accepted' || scenario == 'leave-after-acceptance';
          if (accepted) {
            await _notesVisible(tester, find.text('选存放的文件夹'));
            // Let the directory sheet finish sliding in before tapping an entry.
            await tester.pump(const Duration(milliseconds: 500));
            await tester.tap(find.text('主目录').last);
            await settleMixed(tester, browsers[4].future);
            // Wait on the whole set: `.last` of a not-yet-listed page throws.
            final choose = find.descendant(
              of: find.byType(DirectoryBrowserPage),
              matching: find.byWidgetPredicate((widget) => widget is FilledButton && widget.onPressed != null),
            );
            await _notesVisible(tester, choose);
            // The browser page is still sliding in; tap once it has landed.
            await tester.pump(const Duration(milliseconds: 500));
            await tester.tap(choose.last);
            await settleMixed(tester, postRead.future);
            expect(memory.store.tasks(), hasLength(1));
            if (scenario == 'leave-after-acceptance') {
              await tester.pumpWidget(const SizedBox());
              releasePost.complete();
            }
          }
          await _drained(tester, memory);
          final posts = peer.calls.where((call) => call.method == 'POST' && call.uri.path == notesPath).toList();
          if (!accepted) {
            expect(memory.store.tasks(), isEmpty);
            expect(posts, isEmpty);
          } else {
            expect(posts, hasLength(1));
            expect(possibleAtPost, [now]);
            final request = posts.single.body!;
            final task = memory.store.hostTask(request['taskId']! as String)!;
            expect(request['kind'], 'host.receipts_to_sheet');
            expect(request['args'], receiptAgreement()['args']);
            expect(request['hostSessionId'], _BoundSessions.id);
            expect(request['deadlineAtMs'], DateTime.utc(2026, 11, 21, 12).millisecondsSinceEpoch);
            expect(request['allowQueue'], isTrue);
            expect(request['afterExit'], 'continue');
            expect(task['source_session_id'], sourceRoom);
            expect(task['directory_labels'], {'inputs': inputs, 'outputDirectory': receiptOutput});
            expect(task['state'], 'running');
            if (scenario == 'accepted') {
              await _notesVisible(tester, find.text('看看这件事'));
              await tester.tap(find.text('看看这件事'));
              await _notesVisible(tester, find.byType(CompanionTasksPage));
              await settleMixed(tester, memory.lastReceipt);
              expect(find.text('第 1 份：交通.txt'), findsOneWidget);
              expect(find.text('第 4 份：扫描件.pdf'), findsOneWidget);
            }
            await tester.pumpWidget(const SizedBox());
            memory.dispose();
            disposed = true;
            final reopened = CompanionMemoryStore(
              sqlite3.open('${root.path}/memory.sqlite'),
              nowMilliseconds: () => now,
            );
            expect(reopened.hostTask(request['taskId']! as String)!['directory_labels'], {
              'inputs': inputs,
              'outputDirectory': receiptOutput,
            });
            // Her reply is kept beside it now; the person's source is the one.
            final said = reopened.messages().where((row) => row['role'] == 'user').single;
            expect(said['said_at_utc'], now);
            expect(said['session_id'], sourceRoom);
            reopened.close();
          }
          expect(nativeCalls.where((call) => call.method == 'resolve').single.arguments, {
            'localDate': '2026-11-21',
            'localTime': '20:00',
            'zoneId': 'Asia/Shanghai',
          });
          expect(
            peer.calls.where(
              (call) =>
                  call.uri.path.contains('/sources/') ||
                  call.uri.path.contains('/artifacts/') ||
                  call.uri.path.contains('/session/') ||
                  call.uri.path.contains('/agent/'),
            ),
            isEmpty,
          );
          expect(model.offered.first, contains('receipts_to_sheet'));
          expect(
            model.chats,
            hasLength(switch (scenario) {
              'accepted' => 2,
              'cancel-during-fourth-input' => 3,
              _ => 1,
            }),
          );
          await tester.pumpWidget(const SizedBox());
          // The real HttpClient keeps its idle connection on a 15-second fake-clock timer.
          await tester.pump(const Duration(seconds: 16));
        });
      }

      for (final scenario in [
        'no-saved-inputs',
        'queued-after-two-hundred-tasks',
        'already-possible',
        'compare-only-large-and-pdf',
      ]) {
        testWidgets(
          'J actual Page keeps original offline selections and only first-delivers never-sent tasks: $scenario',
          (tester) async {
            _resumeApp(tester);
            const channel = MethodChannel('dsh/companion_reminders');
            var now = 1795219200000;
            final memory = _ReceiptMemory(
              CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now),
              CompanionLocal.at(root),
              nowMilliseconds: () => now,
            );
            final peer = (await tester.runAsync(NotesPeer.open))!;
            peer.capability = receiptsCapability;
            final checked = Completer<void>();
            final posted = Completer<void>();
            // Her model asks for what was said; compare needs two plain drafts,
            // which four receipts (three too large, one PDF) cannot be.
            final compareOnly = scenario == 'compare-only-large-and-pdf';
            final model = compareOnly
                ? _OfflineTaskModel(
                    compareSpokenExample,
                    _compareCall,
                    failureLine: '先连上原来的电脑，选好 A 旧稿和 B 新稿；还没有可供离线选择的两份原稿。',
                  )
                : _OfflineTaskModel(
                    receiptSpokenExample,
                    _receiptsCall,
                    failureLine: scenario == 'no-saved-inputs' ? '先连回原电脑，选好四张票和放新表的文件夹；没有选过的原件，我不能替你猜。' : null,
                  );
            MemoryRow? snapshot;
            final selectedInputs = [
              for (final input in receiptInputs())
                {
                  ...input,
                  if (scenario == 'compare-only-large-and-pdf' && input['mediaType'] != 'application/pdf')
                    'size': 65537,
                },
            ];
            addTearDown(() async {
              await tester.pumpWidget(const SizedBox());
              memory.dispose();
              await tester.pump();
              await tester.runAsync(peer.close);
              tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
            });
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              channel,
              (call) async => switch (call.method) {
                'clock' => {'utcMs': now, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800},
                'resolve' => {
                  'kind': 'unique',
                  'moments': [
                    {'epochMs': DateTime.utc(2026, 11, 21, 12).millisecondsSinceEpoch, 'offsetSeconds': 28800},
                  ],
                },
                'capabilities' => {'executorId': 'phone-original', 'exact': true, 'notifications': true},
                'recover' => {'recoveryQueued': true},
                _ => throw StateError('Unexpected offline receipt call ${call.method}'),
              },
            );
            peer.respond = (incoming, body) async {
              if (incoming.uri.path == '$notesPath/folders') {
                await NotesPeer.json(incoming, receiptOutput);
              } else if (incoming.uri.path == '$notesPath/inputs') {
                await NotesPeer.json(
                  incoming,
                  selectedInputs.singleWhere((input) => input['displayName'] == body!['name']),
                );
              } else if (incoming.method == 'POST' && incoming.uri.path == notesPath) {
                snapshot = notesSnapshot(body!);
                await NotesPeer.json(incoming, snapshot!, status: 201);
                posted.complete();
              } else if (incoming.method == 'GET' && incoming.uri.path.startsWith('$notesPath/')) {
                if (snapshot != null && incoming.uri.path == '$notesPath/${snapshot!['taskId']}') {
                  await NotesPeer.json(incoming, snapshot!);
                } else {
                  await NotesPeer.json(incoming, {
                    'error': {'code': 'companion/task-not-found', 'message': 'No saved receipt task'},
                  }, status: 404);
                }
                if (!checked.isCompleted) {
                  checked.complete();
                }
              } else {
                await NotesPeer.json(incoming, {
                  'error': {'code': 'companion/not-found', 'message': 'No ordinary file route'},
                }, status: 404);
              }
            };
            await openLight(
              tester,
              apiKey: 'sk-test',
              client: model.client,
              connectionOverride: activeConnectionProvider.overrideWith(
                (ref) => AsyncData(ref.watch(_findConnectionProvider)),
              ),
              extra: [companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
            );
            final container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
            expect(await memoryOf(tester), same(memory));
            await settleMixed(tester, memory.migrateLocal());
            final hostKey = companionHostKey(container.read(activeHostProvider));
            final sourceRoom = memory.store.lightSessionId;
            if (scenario != 'no-saved-inputs') {
              await tester.runAsync(() async {
                final cap = (await peer.client.readCompanionTasksCapability())!;
                final directory = await peer.client.bindCompanionNotesDirectory(cap, '/本人选的输出');
                final inputs = <MemoryRow>[];
                for (final input in selectedInputs) {
                  inputs.add(
                    await peer.client.bindCompanionReceiptInput(
                      cap,
                      folderRef: directory['folderRef']! as String,
                      name: input['displayName']! as String,
                    ),
                  );
                }
                memory.store.submitMessage(
                  id: 'previous-receipts',
                  sessionId: 'light:previous-room',
                  text: receiptSpokenExample,
                  saidAtUtc: now,
                  offsetMinutes: 480,
                  zoneId: 'Asia/Shanghai',
                  offsetSeconds: 28800,
                );
                final old = memory.store.createReceiptsTaskFromMessage(
                  messageId: 'previous-receipts',
                  expectedSourceRev: 1,
                  itemNo: 0,
                  roomMode: 'light',
                  hostKey: hostKey,
                  agreement: receiptAgreement(),
                  inputs: inputs,
                  outputDirectory: directory,
                );
                memory.store.submitMessage(
                  id: 'cancel-previous-receipts',
                  sessionId: 'light:previous-room',
                  text: '取消整理票据。',
                  saidAtUtc: now,
                  offsetMinutes: 480,
                );
                memory.store.cancelReceiptsTask(
                  taskId: old['task_id']! as String,
                  expectedTaskRev: 1,
                  messageId: 'cancel-previous-receipts',
                  expectedSourceRev: 1,
                  itemNo: 0,
                );
              });
            }
            peer.calls.clear();
            void laterTasks(int start) {
              for (var i = start; i < start + 100; i++) {
                now++;
                memory.store.submitMessage(
                  id: 'other-$i',
                  sessionId: 'light:other-room',
                  text: '提醒我处理第$i条',
                  saidAtUtc: now,
                  offsetMinutes: 480,
                );
                memory.store.createReminderFromMessage(
                  messageId: 'other-$i',
                  expectedSourceRev: 1,
                  itemNo: 0,
                  roomMode: 'light',
                  executorId: 'phone-original',
                  reminder: CompanionReminderSpec(text: '处理第$i条', waitReason: 'date_missing'),
                );
              }
            }

            if (scenario == 'queued-after-two-hundred-tasks') {
              laterTasks(0);
              expect(memory.store.tasks().any((row) => row['kind'] == 'host.receipts_to_sheet'), isFalse);
            }
            final saidAt = now;
            await tester.enterText(find.byType(TextField), model.said);
            await tester.pump();
            await tester.tap(find.byIcon(AppIcons.send).last);
            if (compareOnly) {
              await _notesVisible(tester, find.text(model.failureLine!));
              await _drained(tester, memory);
              model.expectTurn();
              expect(memory.store.hostTaskInputs(hostKey: hostKey), hasLength(4));
              expect(memory.store.tasks(sourceSessionId: sourceRoom), isEmpty);
              expect(find.byType(SimpleDialog), findsNothing);
              expect(peer.calls, isEmpty);
              return;
            }
            if (scenario == 'no-saved-inputs') {
              await _notesVisible(tester, find.text(model.failureLine!));
              await _drained(tester, memory);
              model.expectTurn();
              expect(memory.store.tasks(), isEmpty);
              // Her reply is kept beside it now; the person's words are the one source.
              expect(
                memory.store.messages().where((row) => row['role'] == 'user').single['text'],
                receiptSpokenExample,
              );
              expect(peer.calls, isEmpty);
              return;
            }
            await _notesVisible(tester, find.text('选之前选过的第 1 份票据'));
            final handled = memory.lastReceipt;
            for (var i = 0; i < 4; i++) {
              await _notesVisible(tester, find.text('选之前选过的第 ${i + 1} 份票据'));
              // Let the previous dialog finish closing and this one land.
              await tester.pump(const Duration(milliseconds: 500));
              await tester.tap(find.text(receiptInputs()[i]['displayName']! as String));
            }
            await _notesVisible(tester, find.text('把新表放到之前选过的哪个文件夹？'));
            await tester.pump(const Duration(milliseconds: 500));
            await tester.tap(find.text('/本人选的输出'));
            await settleMixed(tester, handled);
            await _drained(tester, memory);
            model.expectTurn();
            final task = memory.store.tasks(sourceSessionId: sourceRoom).single;
            final id = task['task_id']! as String;
            expect((model.result['task']! as Map)['task_id'], id);
            expect(task['state'], 'queued');
            expect(memory.store.hostTask(id)!['directory_labels'], {
              'inputs': receiptInputs(),
              'outputDirectory': receiptOutput,
            });
            expect(memory.store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
            expect(peer.calls, isEmpty);
            if (scenario == 'queued-after-two-hundred-tasks') {
              laterTasks(100);
              expect(memory.store.tasks().any((row) => row['task_id'] == id), isFalse);
            } else {
              final original =
                  memory.store.prepareHostTaskOperation(
                        taskId: id,
                        taskRev: 1,
                        hostKey: hostKey,
                        hostStoreId: 'original-store',
                        initialOpportunity: true,
                      )!['request']!
                      as MemoryRow;
              snapshot = {...notesSnapshot(original, state: 'unknown'), 'waitReason': 'receipt_read_interrupted'};
            }
            container
                .read(_findConnectionProvider.notifier)
                .connect(HostConnection(client: peer.client, isLocal: false));
            await tester.pump();
            await settleMixed(tester, scenario == 'already-possible' ? checked.future : posted.future);
            await settleMixed(tester, memory.lastReceipt);
            await tester.pump();
            final current = memory.store.hostTask(id)!;
            expect(container.read(companionModeProvider), isNull);
            expect(current['room_mode'], 'light');
            expect(current['source_session_id'], sourceRoom);
            expect(current['host_session_id'], isNull);
            expect(current['task_rev'], 1);
            expect(current['state'], scenario == 'already-possible' ? 'unknown' : 'running');
            expect((current['agreement']! as MemoryRow)['args'], receiptAgreement()['args']);
            expect(
              memory.store.messages().singleWhere((row) => row['id'] == task['source_message_id'])['said_at_utc'],
              saidAt,
            );
            expect(
              peer.calls.where((call) => call.method == 'POST' && call.uri.path == notesPath),
              hasLength(scenario == 'already-possible' ? 0 : 1),
            );
            expect(
              peer.calls.where((call) => call.uri.path.endsWith('/inputs') || call.uri.path.endsWith('/folders')),
              isEmpty,
            );
            expect(
              peer.calls.where(
                (call) =>
                    call.method == 'POST' &&
                    (call.uri.path.contains('/session') ||
                        call.uri.path.contains('/prompt') ||
                        call.uri.path.contains('/auxiliary')),
              ),
              isEmpty,
            );
            expect(memory.store.hostTaskCommands(id), hasLength(1));
            // The reconnection resumes the saved command; it plans nothing anew.
            expect(model.ordinary, hasLength(2));
            await tester.pumpWidget(const SizedBox());
            // The real HttpClient keeps its idle connection on a 15-second fake-clock timer.
            await tester.pump(const Duration(seconds: 16));
          },
        );
      }

      for (final scenario in [
        'accepted',
        'source-failure',
        'leave-during-second-input',
        'cancel-during-second-input',
        'leave-after-acceptance',
      ]) {
        testWidgets('I actual Page selects A then B before one durable comparison: $scenario', (tester) async {
          _resumeApp(tester);
          const now = 1795219200000;
          const channel = MethodChannel('dsh/companion_reminders');
          final db = sqlite3.open('${root.path}/memory.sqlite');
          final memory = _ReceiptMemory(
            CompanionMemoryStore(db, nowMilliseconds: () => now),
            CompanionLocal.at(root),
            nowMilliseconds: () => now,
          );
          final peer = (await tester.runAsync(NotesPeer.open))!;
          peer.capability = compareCapability;
          final browsers = [Completer<void>(), Completer<void>()];
          final inputsRead = [Completer<void>(), Completer<void>()];
          final releaseSecond = Completer<void>();
          final postRead = Completer<void>();
          final releasePost = Completer<void>();
          final nativeCalls = <MethodCall>[];
          final sourceAtRead = <List<MemoryRow>>[];
          final taskCountAtBind = <int>[];
          final possibleAtPost = <int?>[];
          MemoryRow? snapshot;
          Future<void>? handling;
          var directoryReads = 0;
          var inputReads = 0;
          // Her model asks for the comparison as said: A then B, by eight
          // tonight, carrying on after she leaves. A cancel only reads tasks.
          final model = _AgentModel.script(
            (said) => said == compareSpokenExample
                ? [_compareCall]
                : said == '取消对稿'
                ? [('task_status', <String, Object?>{})]
                : const [],
            replies: const {'取消对稿': '要停止哪次对稿？请打开那件事再点停止。'},
          );
          var disposed = false;
          addTearDown(() async {
            if (!releaseSecond.isCompleted) {
              releaseSecond.complete();
            }
            if (!releasePost.isCompleted) {
              releasePost.complete();
            }
            await tester.pumpWidget(const SizedBox());
            if (handling != null) {
              await settleMixed(tester, handling);
            }
            if (!disposed) {
              memory.dispose();
            }
            await tester.pump();
            await tester.runAsync(peer.close);
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
          });
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
            nativeCalls.add(call);
            return switch (call.method) {
              'clock' => {'utcMs': now, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800},
              'resolve' => {
                'kind': 'unique',
                'moments': [
                  {'epochMs': DateTime.utc(2026, 11, 21, 12).millisecondsSinceEpoch, 'offsetSeconds': 28800},
                ],
              },
              'capabilities' => {'executorId': 'phone-original', 'exact': true, 'notifications': true},
              'recover' => {'recoveryQueued': true},
              _ => throw StateError('Unexpected native comparison call ${call.method}'),
            };
          });
          peer.respond = (request, body) async {
            if (request.uri.path == '/api/directoryPicker/list') {
              final side = directoryReads++;
              sourceAtRead.add(memory.store.messages().where((row) => row['role'] == 'user').toList());
              await NotesPeer.json(request, {
                'type': 'server-response',
                'rpcId': body!['rpcId'],
                'result': {
                  'ok': true,
                  'value': {
                    'path': '/本人选的稿件',
                    'home': '/本人选的稿件',
                    'crumbs': [
                      {'name': '本人选的稿件', 'path': '/本人选的稿件'},
                    ],
                    'entries': <Object?>[],
                  },
                },
              });
              browsers[side].complete();
            } else if (request.uri.path == '$notesPath/folders') {
              await NotesPeer.json(request, {
                'v': 1,
                'hostStoreId': 'original-store',
                'folderRef': 'bound-drafts',
                'displayPath': '/本人选的稿件',
              });
            } else if (request.uri.path == '$notesPath/inputs') {
              final side = inputReads++;
              taskCountAtBind.add(memory.store.tasks().length);
              inputsRead[side].complete();
              if (side == 1) {
                await releaseSecond.future;
              }
              await NotesPeer.json(request, compareInputs()[side == 0 ? 'a' : 'b']);
            } else if (request.method == 'POST' && request.uri.path == notesPath) {
              final command = memory.store.hostTaskCommands(body!['taskId']! as String).single;
              possibleAtPost.add(command['possible_sent_at_ms'] as int?);
              snapshot = notesSnapshot(body);
              postRead.complete();
              if (scenario == 'leave-after-acceptance') {
                await releasePost.future;
              }
              await NotesPeer.json(request, snapshot!, status: 201);
            } else if (request.method == 'GET' && request.uri.path == '$notesPath/${snapshot?['taskId']}') {
              await NotesPeer.json(request, snapshot!);
            } else {
              await NotesPeer.json(request, {
                'error': {'code': 'companion/task-not-found', 'message': 'No saved comparison'},
              }, status: 404);
            }
          };
          // The full room asks its Host for each model round.
          peer.hostModel.model = () => model.client;
          await openLight(
            tester,
            apiKey: 'sk-test',
            client: model.client,
            connection: HostConnection(client: peer.client, isLocal: false),
            extra: [..._hostRoom, companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
          );
          expect(await memoryOf(tester), same(memory));
          await settleMixed(tester, memory.migrateLocal());
          final sourceRoom = memory.store.lightSessionId;
          if (scenario == 'source-failure') {
            db.execute(
              "CREATE TRIGGER reject_compare BEFORE INSERT ON memory_events "
              "BEGIN SELECT RAISE(ABORT,'fixture disk error'); END",
            );
          }
          await tester.enterText(find.byType(TextField), compareSpokenExample);
          await tester.pump();
          await tester.tap(find.byIcon(AppIcons.send).last);
          if (scenario == 'source-failure') {
            // The source commits before any model round: the ordinary line.
            await _notesVisible(tester, find.text('这句话没送出去，要不要再说一次？'));
            expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
            expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, compareSpokenExample);
            expect(memory.store.messages(), isEmpty);
            expect(memory.store.tasks(), isEmpty);
            expect(_taskCalls(peer), isEmpty);
            expect(model.requests, isEmpty);
            await tester.pumpWidget(const SizedBox());
            // The full room's real HttpClient keeps a 15-second idle timer.
            await tester.pump(const Duration(seconds: 16));
            return;
          }
          for (var side = 0; side < 2; side++) {
            // Wait for this side's own sheet: the previous one may still be closing.
            await _notesVisible(tester, find.text(side == 0 ? '选择 A · 旧稿 所在的文件夹' : '选择 B · 新稿 所在的文件夹'));
            handling ??= memory.lastReceipt;
            // Let the directory sheet finish sliding in before tapping an entry.
            await tester.pump(const Duration(milliseconds: 500));
            await tester.tap(find.text('主目录').last);
            await settleMixed(tester, browsers[side].future);
            // Wait on the whole set: `.last` of a not-yet-listed page throws.
            final choose = find.descendant(
              of: find.byType(DirectoryBrowserPage),
              matching: find.byWidgetPredicate((widget) => widget is FilledButton && widget.onPressed != null),
            );
            await _notesVisible(tester, choose);
            // The browser page is still sliding in; tap once it has landed.
            await tester.pump(const Duration(milliseconds: 500));
            await tester.tap(choose.last);
            final title = side == 0 ? '输入 A · 旧稿 的文件名' : '输入 B · 新稿 的文件名';
            await _notesVisible(tester, find.text(title));
            final dialog = find.byType(AlertDialog);
            await tester.enterText(
              find.descendant(of: dialog, matching: find.byType(TextField)),
              side == 0 ? 'A.md' : 'B.txt',
            );
            await tester.tap(find.descendant(of: dialog, matching: find.text('保存')));
            await settleMixed(tester, inputsRead[side].future);
          }
          // Both selections are actual user actions and HTTP bindings. The B
          // response is still held; no incomplete task may have been accepted.
          expect(taskCountAtBind, [0, 0]);
          expect(memory.store.tasks(), isEmpty);
          expect(peer.calls.where((call) => call.method == 'POST' && call.uri.path == notesPath), isEmpty);
          expect(sourceAtRead, hasLength(2));
          expect(sourceAtRead.every((rows) => rows.length == 1 && rows.single['text'] == compareSpokenExample), isTrue);
          expect(sourceAtRead.first.single['id'], sourceAtRead.last.single['id']);
          expect(sourceAtRead.first.single['first_seq'], sourceAtRead.last.single['first_seq']);
          expect(peer.calls.where((call) => call.uri.path == '$notesPath/inputs').map((call) => call.body), [
            {'v': 1, 'hostStoreId': 'original-store', 'folderRef': 'bound-drafts', 'name': 'A.md'},
            {'v': 1, 'hostStoreId': 'original-store', 'folderRef': 'bound-drafts', 'name': 'B.txt'},
          ]);
          expect(nativeCalls.where((call) => call.method == 'resolve').single.arguments, {
            'localDate': '2026-11-21',
            'localTime': '20:00',
            'zoneId': 'Asia/Shanghai',
          });
          if (scenario == 'leave-during-second-input') {
            await tester.pumpWidget(const SizedBox());
          } else if (scenario == 'cancel-during-second-input') {
            await _notesVisible(tester, find.byType(AlertDialog), absent: true);
            await tester.enterText(find.byType(TextField), '取消对稿');
            await tester.pump();
            expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
            await tester.tap(find.byIcon(AppIcons.send).last);
            await _notesVisible(tester, find.text('要停止哪次对稿？请打开那件事再点停止。'));
          }
          releaseSecond.complete();
          if (scenario == 'leave-after-acceptance') {
            await settleMixed(tester, postRead.future);
            expect(memory.store.tasks(), hasLength(1));
            await tester.pumpWidget(const SizedBox());
            releasePost.complete();
          }
          await _drained(tester, memory);
          final accepted = scenario == 'accepted' || scenario == 'leave-after-acceptance';
          final posts = peer.calls.where((call) => call.method == 'POST' && call.uri.path == notesPath).toList();
          if (!accepted) {
            expect(memory.store.tasks(), isEmpty);
            expect(posts, isEmpty);
          } else {
            expect(posts, hasLength(1));
            expect(possibleAtPost, [now]);
            final request = posts.single.body!;
            final task = memory.store.hostTask(request['taskId']! as String)!;
            expect(request['kind'], 'host.compare_drafts');
            expect(request['args'], compareAgreement()['args']);
            expect(request['hostSessionId'], _BoundSessions.id);
            expect(request['deadlineAtMs'], DateTime.utc(2026, 11, 21, 12).millisecondsSinceEpoch);
            expect(request['allowQueue'], isTrue);
            expect(request['afterExit'], 'continue');
            expect(task['source_session_id'], sourceRoom);
            expect(task['directory_labels'], {'inputs': compareInputs()});
            expect(task['state'], 'running');
            if (scenario == 'accepted') {
              await _notesVisible(tester, find.text('看看这件事'));
              await tester.tap(find.text('看看这件事'));
              await _notesVisible(tester, find.byType(CompanionTasksPage));
              await settleMixed(tester, memory.lastReceipt);
              expect(find.text('A · 旧稿：A.md'), findsOneWidget);
              expect(find.text('B · 新稿：B.txt'), findsOneWidget);
              expect(peer.calls.where((call) => call.method == 'POST' && call.uri.path == notesPath), hasLength(1));
            }
            await tester.pumpWidget(const SizedBox());
            memory.dispose();
            disposed = true;
            final reopened = CompanionMemoryStore(
              sqlite3.open('${root.path}/memory.sqlite'),
              nowMilliseconds: () => now,
            );
            expect(reopened.hostTask(request['taskId']! as String)!['directory_labels'], {'inputs': compareInputs()});
            // Her reply is kept beside it now; the person's source is the one.
            final said = reopened.messages().where((row) => row['role'] == 'user').single;
            expect(said['said_at_utc'], now);
            expect(said['session_id'], sourceRoom);
            reopened.close();
          }
          expect(
            peer.calls.where((call) => call.uri.path.contains('/sources/') || call.uri.path.contains('/artifacts/')),
            isEmpty,
          );
          expect(
            peer.calls.where((call) => call.uri.path.contains('/session/') || call.uri.path.contains('/agent/')),
            isEmpty,
          );
          expect(model.offered.first, contains('compare_drafts'));
          expect(
            model.chats,
            hasLength(switch (scenario) {
              'accepted' => 2,
              'cancel-during-second-input' => 3,
              _ => 1,
            }),
          );
          await tester.pumpWidget(const SizedBox());
          // The real HttpClient keeps its idle connection on a 15-second fake-clock timer.
          await tester.pump(const Duration(seconds: 16));
        });
      }

      for (final scenario in ['no-saved-inputs', 'queued-behind-two-hundred-tasks', 'already-possible']) {
        testWidgets('I actual Page offline input selection and original Host recovery: $scenario', (tester) async {
          _resumeApp(tester);
          const channel = MethodChannel('dsh/companion_reminders');
          var now = 1795219200000;
          final memory = _ReceiptMemory(
            CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now),
            CompanionLocal.at(root),
            nowMilliseconds: () => now,
          );
          final peer = (await tester.runAsync(NotesPeer.open))!;
          peer.capability = compareCapability;
          var seeding = true;
          final model = _OfflineTaskModel(
            compareSpokenExample,
            _compareCall,
            failureLine: scenario == 'no-saved-inputs' ? '先连上原来的电脑，选好 A 旧稿和 B 新稿；还没有可供离线选择的两份原稿。' : null,
          );
          MemoryRow? snapshot;
          final recovered = Completer<void>();
          final posted = Completer<void>();
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            memory.dispose();
            await tester.pump();
            await tester.runAsync(peer.close);
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
          });
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async => switch (call.method) {
              'clock' => {'utcMs': now, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800},
              'resolve' => {
                'kind': 'unique',
                'moments': [
                  {'epochMs': DateTime.utc(2026, 11, 21, 12).millisecondsSinceEpoch, 'offsetSeconds': 28800},
                ],
              },
              'recover' => {'recoveryQueued': true},
              'capabilities' => {'executorId': 'phone-original', 'exact': true, 'notifications': true},
              _ => throw StateError('Unexpected comparison time call ${call.method}'),
            },
          );
          peer.respond = (request, body) async {
            if (request.uri.path == '$notesPath/folders') {
              await NotesPeer.json(request, {
                'v': 1,
                'hostStoreId': 'original-store',
                'folderRef': 'bound-drafts',
                'displayPath': '/本人选的稿件',
              });
            } else if (request.uri.path == '$notesPath/inputs') {
              await NotesPeer.json(request, compareInputs()[body!['name'] == 'A.md' ? 'a' : 'b']);
            } else if (request.method == 'POST' && request.uri.path == notesPath) {
              // Read before replying: the seeding client can return and clear
              // `seeding` while this handler is still closing the response.
              final delivered = !seeding;
              snapshot = {
                ...notesSnapshot(
                  body!,
                  state: seeding ? 'done' : 'running',
                  steps: seeding ? [compareReportStep()] : [],
                ),
                'hostExecutionId': seeding ? 'previous-comparison' : 'new-comparison',
              };
              await NotesPeer.json(request, snapshot!, status: 201);
              if (delivered) {
                posted.complete();
              }
            } else if (request.method == 'GET' && request.uri.path.startsWith('$notesPath/')) {
              if (snapshot != null && request.uri.path == '$notesPath/${snapshot!['taskId']}') {
                await NotesPeer.json(request, snapshot!);
              } else {
                await NotesPeer.json(request, {
                  'error': {'code': 'companion/task-not-found', 'message': 'No saved comparison'},
                }, status: 404);
              }
              if (!seeding && !recovered.isCompleted) {
                recovered.complete();
              }
            } else {
              await NotesPeer.json(request, {
                'error': {'code': 'companion/not-found', 'message': 'No ordinary session route'},
              }, status: 404);
            }
          };
          await openLight(
            tester,
            apiKey: 'sk-test',
            client: model.client,
            connectionOverride: activeConnectionProvider.overrideWith(
              (ref) => AsyncData(ref.watch(_findConnectionProvider)),
            ),
            extra: [companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
          );
          final container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
          expect(await memoryOf(tester), same(memory));
          await settleMixed(tester, memory.migrateLocal());
          final hostKey = companionHostKey(container.read(activeHostProvider));
          final sourceRoom = memory.store.lightSessionId;
          void addOtherTasks(int start) {
            for (var index = start; index < start + 100; index++) {
              now++;
              final id = 'unrelated-$index';
              memory.store.submitMessage(
                id: id,
                sessionId: 'light:other-room',
                text: '提醒我处理第$index条',
                saidAtUtc: now,
                offsetMinutes: 480,
              );
              memory.store.createReminderFromMessage(
                messageId: id,
                expectedSourceRev: 1,
                itemNo: 0,
                roomMode: 'light',
                executorId: 'phone-original',
                reminder: CompanionReminderSpec(text: '处理第$index条', waitReason: 'date_missing'),
              );
            }
          }

          if (scenario != 'no-saved-inputs') {
            // Bind each explicit original through the real client HTTP first.
            // Only those saved responses can later appear in the offline picker.
            await tester.runAsync(() async {
              final capability = (await peer.client.readCompanionTasksCapability())!;
              final folder = await peer.client.bindCompanionNotesDirectory(capability, '/本人选的稿件');
              final inputs = <String, Object?>{};
              for (final side in ['a', 'b']) {
                inputs[side] = await peer.client.bindCompanionDraftInput(
                  capability,
                  folderRef: folder['folderRef']! as String,
                  name: side == 'a' ? 'A.md' : 'B.txt',
                );
              }
              memory.store.submitMessage(
                id: 'old-compare',
                sessionId: 'light:previous-room',
                text: compareSpokenExample,
                saidAtUtc: now,
                offsetMinutes: 480,
                zoneId: 'Asia/Shanghai',
                offsetSeconds: 28800,
              );
              final old = memory.store.createCompareDraftTaskFromMessage(
                messageId: 'old-compare',
                expectedSourceRev: 1,
                itemNo: 0,
                roomMode: 'light',
                hostKey: hostKey,
                inputs: inputs,
                agreement: compareAgreement(),
              );
              final operation = memory.store.prepareHostTaskOperation(
                taskId: old['task_id']! as String,
                taskRev: 1,
                hostKey: hostKey,
                hostStoreId: 'original-store',
                initialOpportunity: true,
              )!;
              final reply = await peer.client.writeCompanionHostTask(
                taskId: old['task_id']! as String,
                operation: 'create',
                request: operation['request']! as MemoryRow,
              );
              memory.store.importHostTaskSnapshot(taskId: old['task_id']! as String, hostKey: hostKey, snapshot: reply);
            });
          }
          seeding = false;
          snapshot = null;
          peer.calls.clear();
          if (scenario == 'queued-behind-two-hundred-tasks') {
            addOtherTasks(0);
            expect(memory.store.tasks().any((row) => row['kind'] == 'host.compare_drafts'), isFalse);
          }
          final saidAt = now;
          await tester.enterText(find.byType(TextField), compareSpokenExample);
          await tester.pump();
          await tester.tap(find.byIcon(AppIcons.send).last);
          if (scenario == 'no-saved-inputs') {
            await _notesVisible(tester, find.text(model.failureLine!));
            await _drained(tester, memory);
            model.expectTurn();
            expect(memory.store.tasks(), isEmpty);
            // Her reply is kept beside it now; the person's words are the one source.
            expect(memory.store.messages().where((row) => row['role'] == 'user').single['text'], compareSpokenExample);
            expect(peer.calls, isEmpty);
            return;
          }
          await _notesVisible(tester, find.text('选择之前选过的 A · 旧稿'));
          final handled = memory.lastReceipt;
          await tester.pump(const Duration(milliseconds: 500));
          await tester.tap(find.text('A.md'));
          await _notesVisible(tester, find.text('选择之前选过的 B · 新稿'));
          // Let the A dialog finish closing and the B one land.
          await tester.pump(const Duration(milliseconds: 500));
          await tester.tap(find.text('B.txt'));
          await settleMixed(tester, handled);
          await _drained(tester, memory);
          model.expectTurn();
          final task = memory.store.tasks(sourceSessionId: sourceRoom).single;
          final id = task['task_id']! as String;
          expect((model.result['task']! as Map)['task_id'], id);
          expect(task['state'], 'queued');
          expect(memory.store.hostTask(id)!['directory_labels'], {'inputs': compareInputs()});
          expect(memory.store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
          expect(peer.calls, isEmpty);
          if (scenario == 'queued-behind-two-hundred-tasks') {
            addOtherTasks(100);
            expect(memory.store.tasks().any((row) => row['task_id'] == id), isFalse);
          } else {
            final original =
                memory.store.prepareHostTaskOperation(
                      taskId: id,
                      taskRev: 1,
                      hostKey: hostKey,
                      hostStoreId: 'original-store',
                      initialOpportunity: true,
                    )!['request']!
                    as MemoryRow;
            snapshot = {...notesSnapshot(original, state: 'unknown'), 'waitReason': 'read_interrupted'};
          }
          container.read(_findConnectionProvider.notifier).connect(HostConnection(client: peer.client, isLocal: false));
          await tester.pump();
          await settleMixed(tester, scenario == 'already-possible' ? recovered.future : posted.future);
          await settleMixed(tester, memory.lastReceipt);
          await tester.pump();
          final current = memory.store.hostTask(id)!;
          expect(container.read(companionModeProvider), isNull);
          expect(container.read(activeConnectionProvider).value!.client, same(peer.client));
          expect(current['source_session_id'], sourceRoom);
          expect(current['room_mode'], 'light');
          expect(current['host_session_id'], isNull);
          expect(current['task_rev'], 1);
          expect(current['state'], scenario == 'already-possible' ? 'unknown' : 'running');
          expect((current['agreement']! as MemoryRow)['args'], compareAgreement()['args']);
          expect(
            memory.store.messages().singleWhere((row) => row['id'] == task['source_message_id'])['said_at_utc'],
            saidAt,
          );
          final creates = peer.calls.where((call) => call.method == 'POST' && call.uri.path == notesPath).toList();
          expect(creates, hasLength(scenario == 'already-possible' ? 0 : 1));
          expect(
            peer.calls.where((call) => call.uri.path.endsWith('/inputs') || call.uri.path.endsWith('/folders')),
            isEmpty,
          );
          expect(
            peer.calls.where(
              (call) =>
                  call.method == 'POST' &&
                  (call.uri.path.contains('/session') ||
                      call.uri.path.contains('/prompt') ||
                      call.uri.path.contains('/auxiliary')),
            ),
            isEmpty,
          );
          expect(memory.store.hostTaskCommands(id), hasLength(1));
          // The reconnection resumes the saved command; it plans nothing anew.
          expect(model.ordinary, hasLength(2));
          await tester.pumpWidget(const SizedBox());
          // The real HttpClient keeps its idle connection on a 15-second fake-clock timer.
          await tester.pump(const Duration(seconds: 16));
        });
      }

      for (final scenario in [
        'accepted',
        'accepted-typed-directory',
        'route-return-before-capability',
        'route-return-during-browser',
        'route-return-during-typed-dialog',
        'route-remove-same-frame-during-sheet',
        'route-remove-same-frame-during-browser',
        'route-return-before-acceptance',
        'host-return-before-acceptance',
        'background-return-before-acceptance',
        'two-fresh-parts',
        'two-parts-then-leave',
        'two-parts-cancel-first',
        'following-find-part',
        'following-cancel-part',
      ]) {
        testWidgets('F fresh Page starts only this accepted foreground batch: $scenario', (tester) async {
          const channel = MethodChannel('dsh/companion_reminders');
          const now = 1795219200000;
          final previousLifecycle = tester.binding.lifecycleState;
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          final memory = _ReceiptMemory(
            CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now),
            CompanionLocal.at(root),
            nowMilliseconds: () => now,
          );
          final peer = (await tester.runAsync(NotesPeer.open))!;
          peer.capability = {...findCapability, 'notesForeground': true};
          final two = scenario.startsWith('two-');
          final followingFind = scenario == 'following-find-part';
          final followingCancel = scenario == 'following-cancel-part';
          final holdAcceptance = scenario.endsWith('before-acceptance');
          final lostDuringSelection =
              scenario == 'route-return-before-capability' ||
              scenario == 'route-return-during-browser' ||
              scenario == 'route-return-during-typed-dialog' ||
              scenario.startsWith('route-remove-same-frame-');
          final typedDirectory = scenario.contains('typed-');
          final capabilitySeen = Completer<void>();
          final releaseCapability = Completer<void>();
          final cancelSeen = Completer<void>();
          final releaseCancel = Completer<void>();
          final cancelBodies = <MemoryRow>[];
          var holdNextCapability = false;
          peer.beforeCapability = () async {
            if (holdNextCapability) {
              holdNextCapability = false;
              capabilitySeen.complete();
              await releaseCapability.future;
            }
          };
          final createSeen = Completer<void>();
          final releaseCreate = Completer<void>();
          final releases = [Completer<void>(), Completer<void>()];
          final imported = [Completer<void>(), Completer<void>()];
          final bindings = [Completer<void>(), Completer<void>()];
          final creations = <MemoryRow>[];
          final snapshots = <String, MemoryRow>{};
          final foregroundPosts = <({String id, MemoryRow body, MemoryRow prepared})>[];
          final taskCountsAtBind = <int>[];
          final receiptFutures = <Future<void>>[];
          // Her model asks for each part as said, one call per round: 甲 (and
          // 乙) paused when she leaves, a following find that carries on, or a
          // following cancel of 甲 by the ID its own result just reported.
          Map<String, Object?> notes(String name) => {
            'operation': 'create',
            'afterExit': 'pause',
            'allowQueue': false,
            'localDate': '2026-11-21',
            'outputName': name,
          };
          final model = _AgentModel.script(
            (said) => !said.startsWith('请电脑把今天的笔记')
                ? const []
                : [
                    ('notes_to_todo', notes('甲待办.md')),
                    if (two) ('notes_to_todo', notes('乙待办.md')),
                    if (followingFind)
                      (
                        'find_draft',
                        <String, Object?>{
                          'operation': 'create',
                          'afterExit': 'continue',
                          'allowQueue': false,
                          'localDate': '2026-11-20',
                          'extensions': ['md', 'txt'],
                          'directoryHint': '演讲稿',
                        },
                      ),
                    if (followingCancel)
                      (
                        'notes_to_todo',
                        (List<Map<String, Object?>> results) {
                          final task = results.single['task']! as Map;
                          return <String, Object?>{
                            'operation': 'cancel',
                            'taskId': task['task_id'],
                            'expectedTaskRev': task['task_rev'],
                          };
                        },
                      ),
                  ],
          );
          // The pause cancel goes to the Host as it is accepted.
          if (followingCancel) releaseCancel.complete();
          Future<void>? handling;
          void changed() {
            for (var index = 0; index < foregroundPosts.length; index++) {
              final task = memory.store.hostTask(foregroundPosts[index].id)!;
              if (task['state'] == 'waiting' &&
                  task['wait_reason'] == 'foreground_required' &&
                  !imported[index].isCompleted) {
                imported[index].complete();
              }
            }
          }

          memory.addListener(changed);
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'clock') {
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
                    'entries': <Object?>[],
                  },
                },
              });
            } else if (request.uri.path == '$notesPath/folders') {
              final index = taskCountsAtBind.length;
              taskCountsAtBind.add(memory.store.tasks().length);
              await NotesPeer.json(request, {
                'v': 1,
                'hostStoreId': 'original-store',
                'folderRef': 'bound-source',
                'displayPath': '/实际笔记',
              });
              bindings[index].complete();
            } else if (request.method == 'POST' && request.uri.path == notesPath) {
              final create = body!;
              creations.add(create);
              final id = create['taskId']! as String;
              final isNotes = create['kind'] == 'host.notes_to_todo';
              snapshots[id] = {
                ...notesSnapshot(create, state: isNotes ? 'waiting' : 'running'),
                'hostExecutionId': 'execution-$id',
                'waitReason': isNotes ? 'foreground_required' : null,
              };
              if (!createSeen.isCompleted) createSeen.complete();
              if (holdAcceptance) await releaseCreate.future;
              await NotesPeer.json(request, snapshots[id], status: 201);
            } else if (request.method == 'POST' && request.uri.path.endsWith('/foreground')) {
              final id = request.uri.pathSegments[request.uri.pathSegments.length - 2];
              final index = foregroundPosts.length;
              foregroundPosts.add((id: id, body: body!, prepared: memory.store.hostTask(id)!));
              final response = request.response
                ..bufferOutput = false
                ..headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
              response.write('${jsonEncode(snapshots[id])}\n');
              await response.flush();
              await releases[index].future;
              try {
                await response.close();
              } on Object {
                // The real Page may already have closed only this response.
              }
            } else if (request.method == 'POST' && request.uri.path.endsWith('/cancel')) {
              final id = request.uri.pathSegments[request.uri.pathSegments.length - 2];
              cancelBodies.add(body!);
              final previous = snapshots[id]!;
              snapshots[id] = {
                ...previous,
                'taskRev': 2,
                'runnerReceiptSeq': 2,
                'state': 'cancelled',
                'waitReason': null,
                'cancelRequested': true,
                'updatedAtMs': now + 2,
                'revisions': [
                  ...(previous['revisions']! as List<Object?>),
                  {'taskRev': 2, 'operation': 'cancel', 'acceptedAtMs': now + 1, 'agreement': previous['agreement']},
                ],
              };
              cancelSeen.complete();
              await releaseCancel.future;
              await NotesPeer.json(request, snapshots[id]);
            } else if (request.method == 'GET' && snapshots.containsKey(request.uri.pathSegments.last)) {
              await NotesPeer.json(request, snapshots[request.uri.pathSegments.last]);
            } else {
              await NotesPeer.json(request, {
                'error': {'code': 'companion/task-not-found', 'message': 'missing'},
              }, status: 404);
            }
          };
          try {
            // The full room asks its Host for each model round.
            peer.hostModel.model = () => model.client;
            await openLight(
              tester,
              apiKey: 'sk-test',
              client: model.client,
              connection: HostConnection(client: peer.client, isLocal: false),
              extra: [..._hostRoom, companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
            );
            expect(await memoryOf(tester), same(memory));
            await settleMixed(tester, memory.migrateLocal());
            final originalSession = memory.store.lightSessionId;
            final element = tester.element(find.byType(CompanionPage));
            final navigator = Navigator.of(element);
            final container = ProviderScope.containerOf(element);
            final originalHost = container.read(activeHostProvider);
            final raw =
                '请电脑把今天的笔记另存成一页待办，原件别动，文件名为《甲待办.md》，我离开就停'
                '${two ? '；请电脑把今天的笔记另存成一页待办，原件别动，文件名为《乙待办.md》，我离开就停' : ''}'
                '${followingFind ? '；请电脑在“演讲稿”本层找昨天改的稿子，不用翻别处，离开后继续' : ''}'
                '${followingCancel ? '；取消《甲待办.md》的笔记整理' : ''}';
            Future<void> externalRouteAndBack() async {
              unawaited(navigator.push<void>(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('外来的页面')))));
              await _notesVisible(tester, find.text('外来的页面'));
              await tester.pump(const Duration(milliseconds: 400));
              navigator.pop();
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 400));
            }

            void externalRouteRemovedInSameFrame(Finder owner) {
              final original = ModalRoute.of(tester.element(owner))!;
              final covering = PageRouteBuilder<void>(
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
                pageBuilder: (_, _, _) => const Scaffold(body: Text('同帧外来页面')),
              );
              unawaited(navigator.push(covering));
              expect(covering.isCurrent, isTrue);
              expect(original.isCurrent, isFalse);
              // No pump or timer occurs between these actual Navigator calls.
              // The owned route's didChangeNext must retain the lost chance.
              navigator.removeRoute(covering);
              expect(original.isCurrent, isTrue);
              expect(find.text('同帧外来页面'), findsNothing);
            }

            holdNextCapability = scenario == 'route-return-before-capability';
            await tester.enterText(find.byType(TextField), raw);
            await tester.pump();
            final turn = memory.receipts.length;
            await tester.tap(find.byIcon(AppIcons.send).last);
            if (scenario == 'route-return-before-capability') {
              await settleMixed(tester, capabilitySeen.future);
              expect(find.byType(DirectoryLocationsSheet), findsNothing);
              expect(memory.store.tasks(), isEmpty);
              await externalRouteAndBack();
              releaseCapability.complete();
              // The window was lost before the picker: none is offered.
              handling = memory.receipts[turn];
            }
            for (
              var choice = 0;
              choice < (scenario == 'route-return-before-capability' ? 0 : (two || followingFind ? 2 : 1));
              choice++
            ) {
              await _notesVisible(tester, find.byType(DirectoryLocationsSheet));
              handling ??= memory.receipts[turn];
              expect(find.byType(CompanionTasksPage), findsNothing);
              expect(foregroundPosts, isEmpty, reason: 'Every picker finishes before the fresh pause batch starts');
              // Each part goes to the Host as it is accepted (its own call);
              // only the foreground start waits for the whole batch.
              expect(creations, hasLength(choice));
              if (scenario == 'route-remove-same-frame-during-sheet') {
                externalRouteRemovedInSameFrame(find.byType(DirectoryLocationsSheet));
              }
              // Let the directory sheet finish sliding in before tapping an entry.
              await tester.pump(const Duration(milliseconds: 500));
              if (typedDirectory) {
                await tester.tap(find.text('输入路径').last);
                await _notesVisible(tester, find.byType(AlertDialog));
                if (scenario == 'route-return-during-typed-dialog') {
                  await externalRouteAndBack();
                }
                await tester.enterText(
                  find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)),
                  '/实际笔记',
                );
                await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
              } else {
                await tester.tap(find.text('主目录').last);
              }
              // `.last` throws on no candidates, so wait for the enabled button
              // (the listing arrives over real HTTP) before narrowing to it.
              final enabledChoose = find.descendant(
                of: find.byType(DirectoryBrowserPage),
                matching: find.byWidgetPredicate((widget) => widget is FilledButton && widget.onPressed != null),
              );
              await _notesVisible(tester, enabledChoose);
              final choose = enabledChoose.last;
              if (scenario == 'route-return-during-browser') {
                await externalRouteAndBack();
              } else if (scenario == 'route-remove-same-frame-during-browser') {
                externalRouteRemovedInSameFrame(find.byType(DirectoryBrowserPage));
              }
              // The browser page slides in too; tap its button once it is on screen.
              await tester.pump(const Duration(milliseconds: 500));
              await tester.tap(choose);
              // A lost window is not bound: the pick ends before the Host.
              if (!lostDuringSelection) await settleMixed(tester, bindings[choice].future);
              // Let this picker finish closing, so the next wait sees only the next sheet.
              if (choice == 0 && (two || followingFind)) await tester.pump(const Duration(milliseconds: 500));
            }
            if (holdAcceptance) {
              await settleMixed(tester, createSeen.future);
              expect(
                memory.store.hostTaskCommands(creations.single['taskId']! as String).single['possible_sent_at_ms'],
                now,
              );
              if (scenario.startsWith('route-')) {
                unawaited(navigator.push<void>(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('另一个页面')))));
                await _notesVisible(tester, find.text('另一个页面'));
                await tester.pump(const Duration(milliseconds: 400));
                navigator.pop();
                // The first frame only starts the reverse animation's ticker.
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 400));
              } else if (scenario.startsWith('host-')) {
                container.read(activeHostProvider.notifier).select(const HostRef.ssh('fresh-other-host'));
                await tester.pump();
                container.read(activeHostProvider.notifier).select(originalHost);
                await tester.pump();
              } else {
                tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
                await tester.pump();
                tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
                await tester.pump();
              }
              releaseCreate.complete();
            }
            await settleMixed(tester, handling!);
            await tester.pump();
            final source = memory.store.messages().singleWhere((row) => row['role'] == 'user');
            expect(source['text'], raw);
            expect(source['session_id'], originalSession);
            expect(taskCountsAtBind, lostDuringSelection ? isEmpty : (two || followingFind ? [0, 1] : [0]));
            expect(model.offered.first, contains('notes_to_todo'));
            expect(
              model.chats,
              hasLength(switch (scenario) {
                _ when two || followingFind || followingCancel => 3,
                'host-return-before-acceptance' => 1,
                _ => 2,
              }),
            );
            if (followingCancel) {
              // 甲 was created as its call was accepted; the following call
              // cancels that revision before any foreground start.
              expect(creations, hasLength(1));
              expect(cancelBodies, hasLength(1));
              expect(foregroundPosts, isEmpty);
              final task = memory.store.tasks().single;
              expect(task['task_rev'], 2);
              expect(task['cancel_requested'], 1);
              expect(task['state'], 'cancelled');
              expect(memory.store.hostTaskCommands(task['task_id']! as String).map((row) => row['operation']), [
                'create',
                'cancel',
              ]);
              expect(find.byType(CompanionTasksPage), findsNothing);
              return;
            }
            if (lostDuringSelection) {
              // A lost window ends the selection before acceptance: the model
              // hears it was not accepted, and nothing is sent or started.
              expect(model.results.first['accepted'], isFalse);
              expect(creations, isEmpty);
              expect(foregroundPosts, isEmpty);
              expect(memory.store.tasks(), isEmpty);
              expect(find.byType(CompanionTasksPage), findsNothing);
              expect(find.text('看看这件事'), findsNothing);
              return;
            }
            expect(creations, hasLength(two || followingFind ? 2 : 1));
            for (final create in creations) {
              expect((create['origin']! as MemoryRow)['messageId'], source['id']);
              expect((create['origin']! as MemoryRow)['sourceSessionId'], originalSession);
              expect(create['hostSessionId'], _BoundSessions.id);
            }
            if (holdAcceptance) {
              expect(foregroundPosts, isEmpty);
              expect(find.byType(CompanionTasksPage), findsNothing);
              expect(memory.store.hostTask(creations.single['taskId']! as String)!['state'], 'waiting');
              if (scenario.startsWith('host-')) {
                // A Host change retires her turn and resets the room, so its
                // pill goes too; the task's own detail is still the way back.
                expect(find.text('看看这件事'), findsNothing);
                unawaited(
                  navigator.push<void>(
                    MaterialPageRoute(
                      builder: (_) => CompanionTasksPage(memory: memory, taskId: creations.single['taskId']! as String),
                    ),
                  ),
                );
              } else {
                await tester.tap(find.text('看看这件事'));
              }
              await _notesVisible(tester, find.byType(CompanionTasksPage));
              await settleMixed(tester, memory.lastReceipt);
              await _notesVisible(tester, find.text('在这里继续'));
              expect(
                foregroundPosts,
                isEmpty,
                reason: 'A later ordinary read cannot restore the lost fresh opportunity',
              );
              return;
            }
            await settleMixed(tester, imported.first.future);
            receiptFutures.add(memory.lastReceipt);
            await _notesVisible(tester, find.byType(CompanionTasksPage));
            expect(find.byType(CompanionTasksPage), findsOneWidget);
            expect(foregroundPosts, hasLength(1), reason: 'The person never tapped the separate continue button');
            final first = foregroundPosts.single;
            expect(first.body, {
              'v': 1,
              'hostStoreId': 'original-store',
              'hostExecutionId': 'execution-${first.id}',
              'taskRev': 1,
              'sourceSessionId': originalSession,
            });
            expect(first.prepared['state'], 'unknown');
            expect(first.prepared['wait_reason'], 'host_receipt_unknown');
            expect(memory.store.hostTaskCommands(first.id), hasLength(1));
            if (followingFind) {
              // Sent in call order; the paused part is still the one started.
              expect(creations.map((create) => create['kind']), ['host.notes_to_todo', 'host.find_draft']);
              expect(first.id, creations.first['taskId']);
            }
            if (scenario == 'two-parts-then-leave') {
              unawaited(navigator.push<void>(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('暂时离开')))));
              await _notesVisible(tester, find.text('暂时离开'));
              await settleMixed(tester, receiptFutures.single);
              navigator.pop();
              await tester.pump(const Duration(milliseconds: 400));
              expect(foregroundPosts, hasLength(1));
              final second = creations.singleWhere((create) => create['taskId'] != first.id);
              expect(memory.store.hostTask(second['taskId']! as String)!['state'], 'waiting');
              expect(memory.store.hostTaskCommands(second['taskId']! as String), hasLength(1));
            } else if (scenario == 'two-parts-cancel-first') {
              // The tasks page slides in; tap its button once it is on screen.
              await tester.pump(const Duration(milliseconds: 500));
              await tester.ensureVisible(find.text('不用整理了'));
              await tester.tap(find.text('不用整理了'));
              await settleMixed(tester, cancelSeen.future);
              final cancellation = memory.lastReceipt;
              expect(memory.store.hostTask(first.id)!['task_rev'], 2);
              expect(memory.store.hostTask(first.id)!['cancel_requested'], 1);
              // The first owned reader retires while the real cancel reply is
              // still held. No refresh or second continue click drives this.
              await settleMixed(tester, receiptFutures.single);
              await tester.pump();
              expect(foregroundPosts, hasLength(1));
              releaseCancel.complete();
              await settleMixed(tester, cancellation);
              await settleMixed(tester, imported[1].future);
              receiptFutures.add(memory.lastReceipt);
              await tester.pump();
              expect(cancelBodies, hasLength(1));
              expect(cancelBodies.single['taskRev'], 2);
              expect(cancelBodies.single['operationId'], memory.store.hostTaskCommands(first.id).last['operation_id']);
              expect(memory.store.hostTask(first.id)!['state'], 'cancelled');
              expect(foregroundPosts, hasLength(2));
              expect(foregroundPosts.last.id, isNot(first.id));
              expect(foregroundPosts.last.body['taskRev'], 1);
              expect(find.textContaining('乙待办.md'), findsWidgets);
            } else if (two) {
              expect(foregroundPosts, hasLength(1));
              releases.first.complete();
              await settleMixed(tester, receiptFutures.single);
              await settleMixed(tester, imported[1].future);
              receiptFutures.add(memory.lastReceipt);
              await tester.pump();
              expect(foregroundPosts, hasLength(2));
              expect(foregroundPosts.map((post) => post.id), creations.map((create) => create['taskId']));
              expect(find.byType(CompanionTasksPage), findsOneWidget);
              expect(find.textContaining('乙待办.md'), findsWidgets);
              expect(creations.map((create) => (create['origin']! as MemoryRow)['itemNo']), [0, 1]);
            }
          } finally {
            if (!releaseCapability.isCompleted) releaseCapability.complete();
            if (!releaseCancel.isCompleted) releaseCancel.complete();
            if (!releaseCreate.isCompleted) releaseCreate.complete();
            for (final release in releases) {
              if (!release.isCompleted) release.complete();
            }
            await tester.pumpWidget(const SizedBox());
            if (handling != null) await settleMixed(tester, handling);
            for (final receipt in receiptFutures) {
              await settleMixed(tester, receipt);
            }
            memory.removeListener(changed);
            memory.dispose();
            await tester.runAsync(peer.close);
            // The inherited real HttpClient owns a 15-second idle timer.
            await tester.pump(const Duration(seconds: 16));
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
            if (previousLifecycle != null) tester.binding.handleAppLifecycleStateChanged(previousLifecycle);
          }
        });
      }

      for (final (kind, scenario) in [
        for (final kind in ['F', 'H'])
          for (final scenario in [
            'accepted',
            'source-failure',
            'leave-during-bind',
            'cancel-during-bind',
            'leave-after-acceptance',
            if (kind == 'H') 'cancel-after-acceptance',
          ])
            (kind, scenario),
      ]) {
        testWidgets('$kind actual Page directory binding and stable source: $scenario', (tester) async {
          _resumeApp(tester);
          final findDraft = kind == 'H';
          final acceptedScenario = const [
            'accepted',
            'leave-after-acceptance',
            'cancel-after-acceptance',
          ].contains(scenario);
          final continued =
              scenario == 'leave-after-acceptance' ||
              (findDraft && const ['accepted', 'cancel-after-acceptance'].contains(scenario));
          const channel = MethodChannel('dsh/companion_reminders');
          const now = 1795219200000;
          final db = sqlite3.open('${root.path}/memory.sqlite');
          final memory = _ReceiptMemory(
            CompanionMemoryStore(db, nowMilliseconds: () => now),
            CompanionLocal.at(root),
            nowMilliseconds: () => now,
          );
          final peer = (await tester.runAsync(NotesPeer.open))!;
          if (findDraft) {
            peer.capability = findCapability;
          }
          final clockRead = Completer<void>();
          final browserRead = Completer<void>();
          final bindRead = Completer<void>();
          final releaseBind = Completer<void>();
          final postReceived = Completer<void>();
          final releasePost = Completer<void>();
          final posted = Completer<void>();
          final cancelled = Completer<void>();
          final resolves = <MethodCall>[];
          final sourceCountsAtBrowse = <int>[];
          final taskCountsAtBind = <int>[];
          final possibleSentAtPost = <Object?>[];
          MemoryRow? cancellationAtPost;
          Map<String, Object?>? creation;
          Map<String, Object?>? snapshot;
          var closed = false;
          // Her model asks for the one task as said (the spoken "seven" is
          // asked back as a choice); a cancel reads the task, then cancels it.
          final hostCall = findDraft
              ? (
                  'find_draft',
                  <String, Object?>{
                    'operation': 'create',
                    'afterExit': continued ? 'continue' : 'pause',
                    'allowQueue': false,
                    'localDate': '2026-11-20',
                    'extensions': ['md', 'txt'],
                    'directoryHint': scenario == 'accepted' ? '演讲稿' : '笔记待办',
                    if (scenario == 'accepted') 'deadlineChoices': ['07:00', '19:00'],
                  },
                )
              : (
                  'notes_to_todo',
                  <String, Object?>{
                    'operation': 'create',
                    'afterExit': continued ? 'continue' : 'pause',
                    'allowQueue': false,
                    'localDate': '2026-11-21',
                  },
                );
          final model = _AgentModel.script(
            (said) => switch (said) {
              '别找了' || '取消这次笔记整理' when scenario == 'cancel-after-acceptance' => [
                ('task_status', <String, Object?>{}),
                (
                  hostCall.$1,
                  (List<Map<String, Object?>> results) {
                    final task = (results.single['tasks']! as List).single as Map;
                    return <String, Object?>{
                      'operation': 'cancel',
                      'taskId': task['task_id'],
                      'expectedTaskRev': task['task_rev'],
                    };
                  },
                ),
              ],
              '别找了' || '取消这次笔记整理' => [('task_status', <String, Object?>{})],
              _ when said.startsWith('请电脑') || said == findSpokenExample => [hostCall],
              _ => const [],
            },
            replies: {
              '别找了': scenario == 'cancel-after-acceptance' ? '已停止继续找，之前找到的清单还在。' : '要停下哪次找稿？可以在交代的事里选。',
              '取消这次笔记整理': '想撤哪一件整理？去「交代的事」里点一下。',
            },
          );
          var cleaned = false;
          // Runs at the end of the body too: the pending-timer check comes
          // before tear-downs.
          Future<void> cleanUp() async {
            if (cleaned) return;
            cleaned = true;
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
            // The inherited real HttpClient owns a 15-second idle timer.
            await tester.pump(const Duration(seconds: 16));
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
          }

          addTearDown(cleanUp);
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
            if (call.method == 'resolve') {
              resolves.add(call);
              return {
                'kind': 'unique',
                'moments': [
                  {'epochMs': DateTime.utc(2026, 11, 21, 11).millisecondsSinceEpoch, 'offsetSeconds': 28800},
                ],
              };
            }
            throw StateError('Unexpected native task call ${call.method}');
          });
          peer.respond = (request, body) async {
            if (request.uri.path == '/api/directoryPicker/list') {
              sourceCountsAtBrowse.add(memory.store.messages().where((row) => row['role'] == 'user').length);
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
              taskCountsAtBind.add(memory.store.tasks().length);
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
              possibleSentAtPost.add(command['possible_sent_at_ms']);
              creation = body;
              snapshot = notesSnapshot(body!, state: continued ? 'running' : 'waiting');
              postReceived.complete();
              if (scenario == 'leave-after-acceptance') {
                await releasePost.future;
              }
              await NotesPeer.json(request, snapshot!, status: 201);
              posted.complete();
            } else if (request.method == 'POST' && request.uri.path == '$notesPath/${creation?['taskId']}/cancel') {
              final id = creation!['taskId']! as String;
              final current = memory.store.hostTask(id)!;
              cancellationAtPost = {
                'taskRev': current['task_rev'],
                'cancelRequested': current['cancel_requested'],
                'sourceText': memory.store.messages().last['text'],
              };
              final agreement = {
                for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: creation![key],
              };
              snapshot = notesSnapshot(
                creation!,
                rev: 2,
                seq: 2,
                state: 'cancelled',
                revisions: [
                  {'taskRev': 1, 'operation': 'create', 'acceptedAtMs': now, 'agreement': agreement},
                  {'taskRev': 2, 'operation': 'cancel', 'acceptedAtMs': now, 'agreement': null},
                ],
              );
              await NotesPeer.json(request, snapshot!);
              cancelled.complete();
            } else if (request.method == 'GET' &&
                snapshot != null &&
                request.uri.path == '$notesPath/${snapshot!['taskId']}') {
              await NotesPeer.json(request, snapshot!);
            } else if (request.method == 'GET' && request.uri.path.startsWith('$notesPath/')) {
              await NotesPeer.json(request, {
                'error': {'code': 'companion/task-not-found', 'message': 'missing'},
              }, status: 404);
            } else {
              await NotesPeer.json(request, {
                'error': {'code': 'companion/not-found', 'message': 'No route'},
              }, status: 404);
            }
          };
          // The full room asks its Host for each model round.
          peer.hostModel.model = () => model.client;
          await openLight(
            tester,
            apiKey: 'sk-test',
            client: model.client,
            connection: HostConnection(client: peer.client, isLocal: false),
            extra: [..._hostRoom, companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
          );
          expect(await memoryOf(tester), same(memory));
          await settleMixed(tester, memory.migrateLocal());
          final sourceRoom = memory.store.lightSessionId;
          if (scenario == 'source-failure') {
            db.execute(
              "CREATE TRIGGER reject_notes_source BEFORE INSERT ON memory_events BEGIN SELECT RAISE(ABORT,'fixture'); END",
            );
          }
          final afterExit = continued ? '我先走了也继续' : '我离开就停';
          final raw = findDraft && scenario == 'accepted'
              ? findSpokenExample
              : findDraft
              ? '请电脑在“笔记待办”本层找昨天改的稿子，不用翻别处，$afterExit；我午后练长笛'
              : '请电脑把今天的笔记另存成一页待办，原件别动，$afterExit；我午后练长笛';
          await tester.enterText(find.byType(TextField), raw);
          await tester.pump();
          final turn = memory.receipts.length;
          await tester.tap(find.byIcon(AppIcons.send).last);
          await settleMixed(tester, clockRead.future);
          if (scenario == 'source-failure') {
            // The source commits before any model round: the ordinary line.
            await _notesVisible(tester, find.text('这句话没送出去，要不要再说一次？'));
            expect(find.text('这句话没送出去，要不要再说一次？'), findsOneWidget);
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
            expect(model.requests, isEmpty);
            expect(resolves, isEmpty);
            await cleanUp();
            return;
          }
          if (findDraft && scenario == 'accepted') {
            await _notesVisible(tester, find.text('你说的七点是上午还是晚上？'));
            expect(memory.store.messages().single['text'], findSpokenExample);
            expect(memory.store.tasks(), isEmpty);
            // Only the read-only capability check comes before the question.
            expect(_taskCalls(peer).where((call) => !call.uri.path.endsWith('/capabilities')), isEmpty);
            await tester.tap(find.text('晚上 19:00'));
          }
          await _notesVisible(tester, find.byType(DirectoryLocationsSheet));
          expect(find.byType(DirectoryLocationsSheet), findsOneWidget);
          final handling = memory.receipts[turn];
          // Let the directory sheet finish sliding in before tapping an entry.
          await tester.pump(const Duration(milliseconds: 500));
          await tester.tap(find.text('主目录').last);
          await settleMixed(tester, browserRead.future);
          // `.last` throws on no candidates; the Page sees the listing a turn
          // after the server wrote it.
          final enabledChoose = find.descendant(
            of: find.byType(DirectoryBrowserPage),
            matching: find.byWidgetPredicate((widget) => widget is FilledButton && widget.onPressed != null),
          );
          await _notesVisible(tester, enabledChoose);
          final choose = enabledChoose.last;
          expect(tester.widget<FilledButton>(choose).onPressed, isNotNull);
          // The browser page slides in too; tap its button once it is on screen.
          await tester.pump(const Duration(milliseconds: 500));
          await tester.tap(choose);
          await settleMixed(tester, bindRead.future);
          expect(sourceCountsAtBrowse, [1]);
          expect(taskCountsAtBind, [0]);
          expect(peer.calls.singleWhere((call) => call.uri.path == '$notesPath/folders').body, {
            'v': 1,
            'hostStoreId': 'original-store',
            'path': '/实际笔记',
          });
          expect(resolves, hasLength(findDraft && scenario == 'accepted' ? 1 : 0));
          if (resolves.isNotEmpty) {
            expect(resolves.single.arguments, {
              'localDate': '2026-11-21',
              'localTime': '19:00',
              'zoneId': 'Asia/Shanghai',
            });
          }
          if (scenario == 'leave-during-bind') {
            await tester.pumpWidget(const SizedBox());
          } else if (scenario == 'cancel-during-bind') {
            await _notesVisible(tester, find.byType(DirectoryLocationsSheet), absent: true);
            await tester.enterText(find.byType(TextField), findDraft ? '别找了' : '取消这次笔记整理');
            await tester.pump();
            expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
            await tester.tap(find.byIcon(AppIcons.send).last);
            await _notesVisible(tester, find.text(findDraft ? '要停下哪次找稿？可以在交代的事里选。' : '想撤哪一件整理？去「交代的事」里点一下。'));
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
            // The full room asks its Host for each model round.
            peer.hostModel.model = () => model.client;
            await openLight(
              tester,
              apiKey: 'sk-test',
              client: model.client,
              connection: HostConnection(client: peer.client, isLocal: false),
              extra: [..._hostRoom, companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
            );
            expect(await memoryOf(tester), same(memory));
            releasePost.complete();
          }
          if (acceptedScenario) {
            await settleMixed(tester, posted.future);
          }
          await settleMixed(tester, handling);
          await tester.pump();
          final sources = memory.store.messages().where((row) => row['role'] == 'user').toList();
          expect(sources.first['text'], raw);
          if (!acceptedScenario) {
            expect(memory.store.tasks(), isEmpty);
            expect(peer.calls.where((call) => call.method == 'POST' && call.uri.path == notesPath), isEmpty);
            expect(possibleSentAtPost, isEmpty);
          } else {
            final body = creation!;
            final args = body['args']! as MemoryRow;
            expect(possibleSentAtPost, [now]);
            expect(
              body['deadlineAtMs'],
              findDraft && scenario == 'accepted' ? DateTime.utc(2026, 11, 21, 11).millisecondsSinceEpoch : null,
            );
            expect(body['afterExit'], continued ? 'continue' : 'pause');
            expect(body['hostSessionId'], _BoundSessions.id);
            expect(body['kind'], findDraft ? 'host.find_draft' : 'host.notes_to_todo');
            expect(args['localDate'], findDraft ? '2026-11-20' : '2026-11-21');
            expect(args['folderRef'], 'bound-source');
            if (findDraft) {
              expect(args['scope'], 'currentLevel');
              expect(args['extensions'], ['md', 'txt']);
              expect(args.containsKey('outputName'), isFalse);
            }
            expect(jsonEncode(body), isNot(contains('练长笛')));
            final row = memory.store.tasks().single;
            expect(row['source_message_id'], sources.single['id']);
            expect(row['source_session_id'], sourceRoom);
            expect(row['item_no'], 0);
            final task = memory.store.hostTask(row['task_id']! as String)!;
            expect(task['state'], continued ? 'running' : 'waiting');
            expect(task['task_rev'], 1);
            expect(task['cancel_requested'], 0);
            expect(task['directory_labels'], {'source': '/实际笔记', if (!findDraft) 'output': '/实际笔记'});
            if (scenario == 'accepted') {
              expect(find.text('看看这件事'), findsOneWidget);
              await tester.tap(find.text('看看这件事'));
              await _notesVisible(tester, find.byType(CompanionTasksPage));
              await settleMixed(tester, memory.lastReceipt);
              // Let the tasks page finish sliding in, so the chat below it is offstage.
              await tester.pump(const Duration(milliseconds: 500));
              expect(find.byType(CompanionTasksPage), findsOneWidget);
              expect(find.text(findDraft ? '查找目录：/实际笔记' : '笔记在：/实际笔记'), findsOneWidget);
              expect(find.textContaining('没法确定你离没离开'), findDraft ? findsNothing : findsOneWidget);
              expect(find.text('让电脑接着做'), findsNothing);
            } else if (scenario == 'cancel-after-acceptance') {
              await tester.enterText(find.byType(TextField), '别找了');
              await tester.pump();
              await tester.tap(find.byIcon(AppIcons.send).last);
              await settleMixed(tester, cancelled.future);
              await _drained(tester, memory);
              expect(memory.store.hostTask(row['task_id']! as String)!['state'], 'cancelled');
              expect(memory.store.hostTaskCommands(row['task_id']! as String), hasLength(2));
              expect(memory.store.messages().last['session_id'], sourceRoom);
              expect(find.text('已停止继续找，之前找到的清单还在。'), findsOneWidget);
              expect(cancellationAtPost, {'taskRev': 2, 'cancelRequested': 1, 'sourceText': '别找了'});
              final cancelPosts = peer.calls.where(
                (call) => call.method == 'POST' && call.uri.path.endsWith('/cancel'),
              );
              expect(cancelPosts, hasLength(1));
              expect(cancelPosts.single.body!['taskRev'], 2);
              expect(cancelPosts.single.body!['kind'], 'host.find_draft');
            } else {
              expect(find.text('看看这件事'), findsNothing);
              expect(find.text('电脑接下这件事了，结果还没出来。'), findsNothing);
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
          expect(model.offered.first, contains(hostCall.$1));
          expect(
            model.chats,
            hasLength(switch (scenario) {
              'accepted' => 2,
              'cancel-during-bind' => 3,
              'cancel-after-acceptance' => 5,
              _ => 1,
            }),
          );
          expect(
            peer.calls.any(
              (call) =>
                  call.method == 'POST' && (call.uri.path.contains('/prompt') || call.uri.path.contains('/auxiliary')),
            ),
            isFalse,
          );
          await cleanUp();
        });
      }

      for (final scenario in ['first-delivery', 'over-one-hundred-tasks-before-and-after', 'already-possible']) {
        testWidgets('H actual Page reconnects a saved light-room find without losing the original queue: $scenario', (
          tester,
        ) async {
          _resumeApp(tester);
          const channel = MethodChannel('dsh/companion_reminders');
          var now = 1795219200000;
          final memory = _ReceiptMemory(
            CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now),
            CompanionLocal.at(root),
            nowMilliseconds: () => now,
          );
          const raw = '等家里电脑开了，在“演讲稿”本层找昨天改的稿子，离开后继续';
          // Her model asks for the find as said: yesterday (the fixed clock's
          // 2026-11-20 in Shanghai), md/txt, queued until the computer is on.
          final model = _OfflineTaskModel(raw, (
            'find_draft',
            <String, Object?>{
              'operation': 'create',
              'localDate': '2026-11-20',
              'extensions': ['md', 'txt'],
              'afterExit': 'continue',
              'allowQueue': true,
            },
          ));
          void addLaterTasks(int start) {
            for (var i = start; i < start + 100; i++) {
              now++;
              memory.store.submitMessage(
                id: 'later-$i',
                sessionId: 'light:other-room',
                text: '提醒我处理第$i条',
                saidAtUtc: now,
                offsetMinutes: 480,
              );
              memory.store.createReminderFromMessage(
                messageId: 'later-$i',
                expectedSourceRev: 1,
                itemNo: 0,
                roomMode: 'light',
                executorId: 'phone-original',
                reminder: CompanionReminderSpec(text: '处理第$i条', waitReason: 'date_missing'),
              );
            }
          }

          final peer = (await tester.runAsync(NotesPeer.open))!;
          peer.capability = findCapability;
          final readBack = Completer<void>();
          final posted = Completer<void>();
          Map<String, Object?>? snapshot;
          var seeding = true;
          final bindingDuringSeed = <bool>[];
          var cleaned = false;
          // Runs at the end of the body too: the pending-timer check comes
          // before tear-downs.
          Future<void> cleanUp() async {
            if (cleaned) return;
            cleaned = true;
            await tester.pumpWidget(const SizedBox());
            memory.dispose();
            await tester.pump();
            await tester.runAsync(peer.close);
            // The inherited real HttpClient owns a 15-second idle timer.
            await tester.pump(const Duration(seconds: 16));
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
          }

          addTearDown(cleanUp);
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async => switch (call.method) {
              'clock' => {'utcMs': now, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800},
              'recover' => {'recoveryQueued': true},
              'capabilities' => {'executorId': 'phone-original', 'exact': true, 'notifications': true},
              _ => throw StateError('Unexpected native task call ${call.method}'),
            },
          );
          peer.respond = (request, body) async {
            if (request.uri.path == '$notesPath/folders') {
              bindingDuringSeed.add(seeding);
              await NotesPeer.json(request, {
                'v': 1,
                'hostStoreId': 'original-store',
                'folderRef': 'bound-source',
                'displayPath': '/本人选的稿件',
              });
            } else if (request.uri.path == notesPath && request.method == 'POST') {
              snapshot = notesSnapshot(
                body!,
                state: seeding ? 'done' : 'running',
                steps: seeding ? [findReportStep()] : [],
              );
              await NotesPeer.json(request, snapshot!, status: 201);
              if (!seeding && !posted.isCompleted) {
                posted.complete();
              }
            } else if (request.method == 'GET' && request.uri.path.startsWith('$notesPath/')) {
              if (snapshot != null && request.uri.path == '$notesPath/${snapshot!['taskId']}') {
                await NotesPeer.json(request, snapshot!);
              } else {
                await NotesPeer.json(request, {
                  'error': {'code': 'companion/task-not-found', 'message': 'missing'},
                }, status: 404);
              }
              if (!readBack.isCompleted) {
                readBack.complete();
              }
            } else {
              // Normal full-room capability/migration reads may also occur
              // after reconnect. They do not authorize a find or model call.
              await NotesPeer.json(request, {
                'error': {'code': 'companion/not-found', 'message': 'No route'},
              }, status: 404);
            }
          };
          await openLight(
            tester,
            apiKey: 'sk-test',
            client: model.client,
            connectionOverride: activeConnectionProvider.overrideWith(
              (ref) => AsyncData(ref.watch(_findConnectionProvider)),
            ),
            extra: [companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
          );
          final container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
          expect(await memoryOf(tester), same(memory));
          await settleMixed(tester, memory.migrateLocal());
          final hostKey = companionHostKey(container.read(activeHostProvider));
          final sourceRoom = memory.store.lightSessionId;
          expect(container.read(companionModeProvider), isNull);
          expect(container.read(activeConnectionProvider).value, isNull);

          // Establish a previous real HTTP directory binding and complete
          // task receipt. Later offline selection reads this persisted record.
          await tester.runAsync(() async {
            final capability = (await peer.client.readCompanionTasksCapability())!;
            final bound = await peer.client.bindCompanionNotesDirectory(capability, '/本人选的稿件');
            memory.store.submitMessage(
              id: 'previous-find',
              sessionId: 'light:previous-room',
              text: '请电脑在“稿件”本层找昨天改的文件，离开后继续',
              saidAtUtc: now,
              offsetMinutes: 480,
              offsetSeconds: 28800,
              zoneId: 'Asia/Shanghai',
            );
            final prior = memory.store.createFindDraftTaskFromMessage(
              messageId: 'previous-find',
              expectedSourceRev: 1,
              itemNo: 0,
              roomMode: 'light',
              hostKey: hostKey,
              directoryHostStoreId: bound['hostStoreId']! as String,
              agreement: findAgreement(),
              directoryLabels: {'source': bound['displayPath']},
            );
            final command = memory.store.prepareHostTaskOperation(
              taskId: prior['task_id']! as String,
              taskRev: 1,
              hostKey: hostKey,
              hostStoreId: 'original-store',
              initialOpportunity: true,
            )!;
            final receipt = await peer.client.writeCompanionHostTask(
              taskId: prior['task_id']! as String,
              operation: 'create',
              request: command['request']! as MemoryRow,
            );
            memory.store.importHostTaskSnapshot(
              taskId: prior['task_id']! as String,
              hostKey: hostKey,
              snapshot: receipt,
            );
          });
          seeding = false;
          snapshot = null;
          peer.calls.clear();
          if (scenario == 'over-one-hundred-tasks-before-and-after') {
            addLaterTasks(0);
            expect(memory.store.tasks().any((row) => row['kind'] == 'host.find_draft'), isFalse);
          }
          final saidAt = now;
          await tester.enterText(find.byType(TextField), raw);
          await tester.pump();
          await tester.tap(find.byIcon(AppIcons.send).last);
          await _notesVisible(tester, find.text('选一个之前用过的文件夹'));
          final handled = memory.lastReceipt;
          // Let the saved-directory choice finish sliding in.
          await tester.pump(const Duration(milliseconds: 500));
          await tester.tap(find.text('/本人选的稿件'));
          await settleMixed(tester, handled);
          await _drained(tester, memory);
          model.expectTurn();
          final task = memory.store.tasks(sourceSessionId: sourceRoom).single;
          final id = task['task_id']! as String;
          expect((model.result['task']! as Map)['task_id'], id);
          final source = memory.store.messages().singleWhere((row) => row['id'] == task['source_message_id']);
          expect(source['text'], raw);
          expect(source['said_at_utc'], saidAt);
          expect(memory.store.hostTask(id)!['host_store_id'], 'original-store');
          expect(memory.store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
          expect(peer.calls, isEmpty);

          if (scenario == 'over-one-hundred-tasks-before-and-after') {
            addLaterTasks(100);
            expect(memory.store.tasks().any((row) => row['task_id'] == id), isFalse);
          } else if (scenario == 'already-possible') {
            final original =
                memory.store.prepareHostTaskOperation(
                      taskId: id,
                      taskRev: 1,
                      hostKey: hostKey,
                      hostStoreId: 'original-store',
                      initialOpportunity: true,
                    )!['request']!
                    as Map<String, Object?>;
            snapshot = {...notesSnapshot(original, state: 'unknown'), 'waitReason': 'scan_interrupted'};
          }
          // This changes the same live provider observed by Page. No explicit
          // mode was selected, so this actual connection also changes light to full.
          container.read(_findConnectionProvider.notifier).connect(HostConnection(client: peer.client, isLocal: false));
          await tester.pump();
          await settleMixed(tester, scenario == 'already-possible' ? readBack.future : posted.future);
          await settleMixed(tester, memory.lastReceipt);
          // The reconnect resume is not a retained receipt: after the peer
          // writes its reply, the Page still has to read and import it (the
          // task shows 'unknown' while the create is possibly sent).
          final settledState = scenario == 'already-possible' ? 'unknown' : 'running';
          for (var i = 0; i < 200 && memory.store.hostTask(id)!['state'] != settledState; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
            await tester.pump();
          }
          await tester.pump();
          final current = memory.store.hostTask(id)!;
          expect(container.read(companionModeProvider), isNull);
          expect(container.read(activeConnectionProvider).value!.client, same(peer.client));
          expect(current['source_session_id'], sourceRoom);
          expect(current['room_mode'], 'light');
          expect(current['host_session_id'], isNull);
          expect(current['task_rev'], 1);
          expect(current['state'], scenario == 'already-possible' ? 'unknown' : 'running');
          expect((current['agreement']! as MemoryRow)['args'], findAgreement()['args']);
          final creates = peer.calls.where((call) => call.method == 'POST' && call.uri.path == notesPath).toList();
          expect(creates, hasLength(scenario == 'already-possible' ? 0 : 1));
          if (creates.isNotEmpty) {
            expect(creates.single.body!['origin'], {
              'sourceSessionId': sourceRoom,
              'messageId': source['id'],
              'itemNo': 0,
            });
          }
          expect(peer.calls.any((call) => call.uri.path.endsWith('/folders')), isFalse);
          expect(bindingDuringSeed, [
            true,
          ], reason: 'Offline selection must reuse the saved binding, not bind a path again');
          expect(
            peer.calls.any(
              (call) =>
                  call.method == 'POST' && (call.uri.path.contains('/prompt') || call.uri.path.contains('/auxiliary')),
            ),
            isFalse,
          );
          expect(memory.store.hostTaskCommands(id), hasLength(1));
          // The reconnection resumes the saved command; it plans nothing anew.
          expect(model.ordinary, hasLength(2));
          await cleanUp();
        });
      }

      for (final operation in ['amend', 'cancel']) {
        for (final duplicate in [false, true]) {
          testWidgets('R18 actual Page $operation keeps older reminder identity, duplicate=$duplicate', (tester) async {
            final beforeLifecycle = tester.binding.lifecycleState;
            tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
            addTearDown(() {
              if (beforeLifecycle != null) {
                tester.binding.handleAppLifecycleStateChanged(beforeLifecycle);
              } else {
                tester.binding.resetInternalState();
              }
            });
            const channel = MethodChannel('dsh/companion_reminders');
            var now = DateTime.utc(2026, 11, 21, 10).millisecondsSinceEpoch;
            final db = sqlite3.open('${root.path}/memory.sqlite');
            final memory = _ReceiptMemory(
              CompanionMemoryStore(db, nowMilliseconds: () => now),
              CompanionLocal.at(root),
              nowMilliseconds: () => now,
            );
            final calls = <MethodCall>[];
            var posts = 0;
            addTearDown(() async {
              memory.receiptStarted = null;
              await tester.pumpWidget(const SizedBox());
              memory.dispose();
              await tester.pump();
              tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
            });
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              switch (call.method) {
                case 'clock':
                  return {'utcMs': now, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800};
                case 'capabilities':
                  return {'executorId': 'installation-A', 'exact': true, 'notifications': true};
                case 'resolve':
                  final args = call.arguments as Map;
                  final local = DateTime.parse('${args['localDate']}T${args['localTime']}Z');
                  return {
                    'kind': 'unique',
                    'moments': [
                      {'epochMs': local.millisecondsSinceEpoch - 28800000, 'offsetSeconds': 28800},
                    ],
                  };
                case 'recover':
                  return {'recoveryQueued': true};
                case 'wake':
                  final task = memory.store.task((call.arguments as Map)['taskId']! as String)!;
                  if (task['task_rev'] == 1) {
                    // Controlled native receipt input, not an Android alarm.
                    // Later amend/cancel wakes only ACK; they cannot prove stop.
                    for (final event in ['claimed', 'returned']) {
                      db.execute(
                        '''
                        INSERT INTO companion_task_receipts(task_id,task_rev,step_key,attempt_id,event_kind,
                          executor_id,occurred_at_ms,outcome)
                        VALUES(?,1,'alarm.register','r18-page-register',?,'installation-A',?,?)
                      ''',
                        [task['task_id'], event, now, event == 'returned' ? 'succeeded' : null],
                      );
                    }
                    db.execute("UPDATE companion_task_revisions SET state='done' WHERE task_id=? AND task_rev=1", [
                      task['task_id'],
                    ]);
                  }
                  return {'wakeCompleted': true};
                default:
                  throw StateError('Unexpected reminder method ${call.method}');
              }
            });
            // The phone model plans each turn (A1): scripted replies stand in
            // for its tool calls; every other request (memory upkeep) is refused.
            final script = <http.Response Function(Map<String, Object?>)>[];
            final chats = <Map<String, Object?>>[];
            await openLight(
              tester,
              apiKey: 'sk-test',
              client: MockClient((request) async {
                final body = jsonDecode(request.body) as Map<String, Object?>;
                if (!_isChat2(body)) return http.Response('', 401);
                posts++;
                chats.add(body);
                return script.removeAt(0)(body);
              }),
              extra: [companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
            );
            expect(await memoryOf(tester), same(memory));
            await settleMixed(tester, memory.migrateLocal());

            Future<void> sendReminder(String raw, List<http.Response Function(Map<String, Object?>)> replies) async {
              script.addAll(replies);
              await tester.enterText(find.byType(TextField), raw);
              await tester.pump();
              await tester.tap(find.byIcon(AppIcons.send).last);
              await _until2(
                tester,
                () => script.isEmpty && !tester.widget<CompanionComposer>(find.byType(CompanionComposer)).running,
              );
              await settleMixed(tester, memory.lastReceipt);
              await tester.pump();
              expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
            }

            const originalRaw = '2026-11-22 08:00 Asia/Shanghai提醒我带证件';
            await sendReminder(originalRaw, [
              (_) => _reply2(
                calls: [
                  (
                    'r18-create',
                    'reminder',
                    {
                      'operation': 'create',
                      'text': '带证件',
                      'localDate': '2026-11-22',
                      'localTime': '08:00',
                      'zoneId': 'Asia/Shanghai',
                    },
                  ),
                ],
              ),
              (_) => _reply2(words: '好，到点叫你带证件。'),
            ]);
            final original = memory.store.tasks().single;
            final id = original['task_id']! as String;
            final source = memory.store.messages().singleWhere((row) => row['text'] == originalRaw);
            final sourceBefore = Map<String, Object?>.from(
              db.select('SELECT * FROM memory_messages WHERE id=?', [source['id']]).single,
            );
            expect(original['state'], 'done');
            expect(memory.store.taskReceipts(id), hasLength(2));
            final room = memory.store.lightSessionId;

            MemoryRow addLater(String sourceId, String text) {
              now++;
              memory.store.submitMessage(
                id: sourceId,
                sessionId: room,
                text: '2026-11-22 08:00 Asia/Shanghai提醒我$text',
                saidAtUtc: now,
                offsetMinutes: 480,
                zoneId: 'Asia/Shanghai',
                offsetSeconds: 28800,
              );
              return memory.store.createReminderFromMessage(
                messageId: sourceId,
                expectedSourceRev: 1,
                itemNo: 0,
                roomMode: 'light',
                executorId: 'installation-A',
                reminder: CompanionReminderSpec(
                  text: text,
                  localDate: '2026-11-22',
                  localTime: '08:00',
                  zoneId: 'Asia/Shanghai',
                  offsetSeconds: 28800,
                  epochMs: DateTime.utc(2026, 11, 22).millisecondsSinceEpoch,
                ),
              );
            }

            for (var index = 0; index < 100; index++) {
              addLater('newer-$index', '处理第$index件事');
            }
            final other = duplicate ? addLater('independent-same-text', '带证件') : null;
            final visible = memory.store.tasks(sourceSessionId: room);
            expect(visible, hasLength(100));
            expect(visible.map((row) => row['task_id']), isNot(contains(id)));
            expect(
              visible.where((row) => row['reminder_text'] == '带证件').map((row) => row['task_id']),
              duplicate ? [other!['task_id']] : isEmpty,
            );
            final headsBefore = [
              for (final row in db.select('SELECT * FROM companion_tasks ORDER BY task_id'))
                Map<String, Object?>.from(row),
            ];
            final revisionsBefore = [
              for (final row in db.select('SELECT * FROM companion_task_revisions ORDER BY task_id,task_rev'))
                Map<String, Object?>.from(row),
            ];
            final receiptsBefore = [
              for (final row in db.select('SELECT * FROM companion_task_receipts ORDER BY runner_receipt_seq'))
                Map<String, Object?>.from(row),
            ];
            calls.clear();
            now++;
            final raw = operation == 'amend' ? '把带证件的提醒改到08:30' : '取消带证件的提醒';
            // The model, not a sentence parser, picks the target: it reads the
            // original receipt by its exact ID before amending or cancelling.
            // With a namesake in the room it reads the bounded list instead,
            // which cannot prove the older one, and asks which one was meant.
            const which = '你说的是哪一条？去「交代的事」里点给我看看。';
            Map<String, Object?>? listed;
            Map<String, Object?>? changedResult;
            await sendReminder(raw, [
              if (duplicate) ...[
                (_) => _reply2(calls: [('r18-list', 'task_status', <String, Object?>{})]),
                (body) {
                  listed = _toolResult2(body);
                  return _reply2(words: which);
                },
              ] else ...[
                (_) => _reply2(
                  calls: [
                    ('r18-read', 'task_status', {'taskId': id}),
                  ],
                ),
                (body) {
                  expect(((_toolResult2(body)['task']! as Map)['task_id']), id);
                  return _reply2(
                    calls: [
                      (
                        'r18-change',
                        'reminder',
                        {
                          'operation': operation,
                          'taskId': id,
                          'expectedTaskRev': 1,
                          if (operation == 'amend') 'localTime': '08:30',
                        },
                      ),
                    ],
                  );
                },
                (body) {
                  changedResult = _toolResult2(body);
                  final task = changedResult!['task']! as Map;
                  // Her words come only from the receipt the tool returned.
                  final words = task['cancel_requested'] == 1 && task['state'] == 'queued'
                      ? '${task['reminder_text']}：取消的要求已记下，还没确认这条提醒已撤下。'
                      : '${task['reminder_text']}：改好了。';
                  return _reply2(words: words);
                },
              ],
            ]);
            final command = memory.store.messages().singleWhere((row) => row['text'] == raw);
            expect(command['session_id'], room);
            expect(command['id'], isNot(source['id']));
            expect(command['source_rev'], 1);
            final accepted = memory.store.taskForCommand(command['id']! as String, 0);
            final headsAfter = [
              for (final row in db.select('SELECT * FROM companion_tasks ORDER BY task_id'))
                Map<String, Object?>.from(row),
            ];
            final revisionsAfter = [
              for (final row in db.select('SELECT * FROM companion_task_revisions ORDER BY task_id,task_rev'))
                Map<String, Object?>.from(row),
            ];
            expect([
              for (final row in db.select('SELECT * FROM companion_task_receipts ORDER BY runner_receipt_seq'))
                Map<String, Object?>.from(row),
            ], receiptsBefore);
            if (duplicate) {
              expect(accepted, isNull);
              expect(headsAfter, headsBefore);
              expect(revisionsAfter, revisionsBefore);
              expect(calls.where((call) => const ['capabilities', 'resolve', 'wake'].contains(call.method)), isEmpty);
              expect(listed!['readOnly'], isTrue);
              expect(listed!['limited'], isTrue);
              final rows = (listed!['tasks']! as List).cast<Map>();
              expect(rows.map((row) => row['task_id']), isNot(contains(id)));
              expect(rows.where((row) => row['reminder_text'] == '带证件').map((row) => row['task_id']), [
                other!['task_id'],
              ]);
              expect(find.text(which), findsOneWidget);
            } else {
              expect(changedResult!['accepted'], isTrue);
              expect((changedResult!['task']! as Map)['task_id'], id);
              expect(accepted!['task_id'], id);
              expect(accepted['task_rev'], 2);
              expect(accepted['source_message_id'], source['id']);
              expect(accepted['source_session_id'], room);
              expect(accepted['command_message_id'], command['id']);
              expect(accepted['command_source_rev'], 1);
              expect(accepted['command_item_no'], 0);
              expect(accepted['operation'], operation);
              expect(accepted['cancel_requested'], operation == 'cancel' ? 1 : 0);
              expect(accepted['state'], 'queued', reason: 'A wake ACK is neither a new alarm nor a stop receipt');
              if (operation == 'cancel') {
                expect(find.text('带证件：取消的要求已记下，还没确认这条提醒已撤下。'), findsOneWidget);
                expect(find.textContaining('正在帮你设'), findsNothing);
                expect(find.text('带证件：好，这条不提醒了。'), findsNothing);
              }
              expect(accepted['local_time'], operation == 'amend' ? '08:30' : '08:00');
              expect(headsAfter, hasLength(headsBefore.length));
              expect(headsAfter.where((row) => row['task_id'] != id), headsBefore.where((row) => row['task_id'] != id));
              expect(revisionsAfter, hasLength(revisionsBefore.length + 1));
              expect(revisionsAfter.where((row) => row['task_id'] != id || row['task_rev'] == 1), revisionsBefore);
              final wakes = calls.where((call) => call.method == 'wake').toList();
              expect(wakes, hasLength(1));
              expect(wakes.single.arguments, {'taskId': id});
              expect(calls.where((call) => call.method == 'resolve'), hasLength(operation == 'amend' ? 1 : 0));
              expect(find.text(which), findsNothing);
            }
            expect(
              Map<String, Object?>.from(db.select('SELECT * FROM memory_messages WHERE id=?', [source['id']]).single),
              sourceBefore,
            );
            // Only the scripted chat turns went out: two for the original
            // reminder, then this instruction's reads, change and reply.
            expect(posts, 2 + (duplicate ? 2 : 3));
            expect((chats.first['tools']! as List).cast<Map>().map((tool) => tool['name']), contains('reminder'));
          });
        }
      }

      for (final hostWindow in [false, true]) {
        testWidgets(
          hostWindow
              ? 'R22 earlier errands refreshes phone capability beyond a Host-only window without execution'
              : 'R22 ambiguous reminder opens earlier errands and cancels only the chosen old task',
          (tester) async {
            final beforeLifecycle = tester.binding.lifecycleState;
            tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
            addTearDown(() {
              if (beforeLifecycle != null) {
                tester.binding.handleAppLifecycleStateChanged(beforeLifecycle);
              } else {
                tester.binding.resetInternalState();
              }
            });
            const channel = MethodChannel('dsh/companion_reminders');
            var now = DateTime.utc(2026, 11, 21, 10).millisecondsSinceEpoch;
            final db = sqlite3.open('${root.path}/memory.sqlite');
            final memory = _ReceiptMemory(
              CompanionMemoryStore(db, nowMilliseconds: () => now),
              CompanionLocal.at(root),
              nowMilliseconds: () => now,
            );
            final calls = <MethodCall>[];
            var posts = 0;
            addTearDown(() async {
              memory.receiptStarted = null;
              await tester.pumpWidget(const SizedBox());
              memory.dispose();
              await tester.pump();
              tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
            });
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              switch (call.method) {
                case 'clock':
                  return {'utcMs': now, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800};
                case 'capabilities':
                  return {'executorId': 'installation-A', 'exact': true, 'notifications': true};
                case 'resolve':
                  final args = call.arguments as Map;
                  final local = DateTime.parse('${args['localDate']}T${args['localTime']}Z');
                  return {
                    'kind': 'unique',
                    'moments': [
                      {'epochMs': local.millisecondsSinceEpoch - 28800000, 'offsetSeconds': 28800},
                    ],
                  };
                case 'recover':
                  return {'recoveryQueued': true};
                case 'wake':
                  final task = memory.store.task((call.arguments as Map)['taskId']! as String)!;
                  if (task['task_rev'] == 1) {
                    // Controlled native-boundary facts, not a real alarm or notification.
                    // Cancellation below receives only a wake ACK.
                    for (final event in ['claimed', 'returned']) {
                      db.execute(
                        '''
                        INSERT INTO companion_task_receipts(task_id,task_rev,step_key,attempt_id,event_kind,
                          executor_id,occurred_at_ms,outcome)
                        VALUES(?,1,'alarm.register','r22-page-register',?,'installation-A',?,?)
                      ''',
                        [task['task_id'], event, now, event == 'returned' ? 'succeeded' : null],
                      );
                    }
                    db.execute("UPDATE companion_task_revisions SET state='done' WHERE task_id=? AND task_rev=1", [
                      task['task_id'],
                    ]);
                  }
                  return {'wakeCompleted': true};
                default:
                  throw StateError('Unexpected reminder method ${call.method}');
              }
            });
            // The phone model plans each turn (A1): scripted replies stand in
            // for its tool calls; every other request (memory upkeep) is refused.
            final script = <http.Response Function(Map<String, Object?>)>[];
            await openLight(
              tester,
              apiKey: 'sk-test',
              client: MockClient((request) async {
                final body = jsonDecode(request.body) as Map<String, Object?>;
                if (!_isChat2(body)) return http.Response('', 401);
                posts++;
                return script.removeAt(0)(body);
              }),
              extra: [companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory)],
            );
            expect(await memoryOf(tester), same(memory));
            await settleMixed(tester, memory.migrateLocal());

            Future<void> say(String raw, List<http.Response Function(Map<String, Object?>)> replies) async {
              script.addAll(replies);
              await tester.enterText(find.byType(TextField), raw);
              await tester.pump();
              await tester.tap(find.byIcon(AppIcons.send).last);
              await _until2(
                tester,
                () => script.isEmpty && !tester.widget<CompanionComposer>(find.byType(CompanionComposer)).running,
              );
              await settleMixed(tester, memory.lastReceipt);
              await tester.pump();
              expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
            }

            List<http.Response Function(Map<String, Object?>)> create(String date) => [
              (_) => _reply2(
                calls: [
                  (
                    'r22-create-$date',
                    'reminder',
                    {
                      'operation': 'create',
                      'text': '带证件',
                      'localDate': date,
                      'localTime': '08:00',
                      'zoneId': 'Asia/Shanghai',
                    },
                  ),
                ],
              ),
              (_) => _reply2(words: '好，到点叫你带证件。'),
            ];

            List<MemoryRow> readRows(String sql) => [for (final row in db.select(sql)) Map<String, Object?>.from(row)];
            List<List<MemoryRow>> ledger() => [
              readRows('SELECT * FROM companion_tasks ORDER BY task_id'),
              readRows('SELECT * FROM companion_task_revisions ORDER BY task_id,task_rev'),
              readRows('SELECT * FROM companion_task_receipts ORDER BY runner_receipt_seq'),
            ];
            const originalRaw = '2026-11-23 08:00 Asia/Shanghai提醒我带证件';
            await say(originalRaw, create('2026-11-23'));
            final original = memory.store.tasks().single;
            final id = original['task_id']! as String;
            final room = memory.store.lightSessionId;
            final originalSource = memory.store.messages().singleWhere((row) => row['text'] == originalRaw);
            final sourceBefore = Map<String, Object?>.from(
              db.select('SELECT * FROM memory_messages WHERE id=?', [originalSource['id']]).single,
            );
            expect(original['state'], 'done');
            expect(memory.store.taskReceipts(id), hasLength(2));

            void addLater(int index) {
              now++;
              final sourceId = 'r22-later-$index';
              memory.store.submitMessage(
                id: sourceId,
                sessionId: room,
                text: hostWindow ? '电脑连上以后，把今天的笔记存成第$index页待办' : '2026-11-25 08:00提醒我处理第$index件事',
                saidAtUtc: now,
                offsetMinutes: 480,
                zoneId: 'Asia/Shanghai',
                offsetSeconds: 28800,
              );
              if (hostWindow) {
                // Real local queued Host tasks. No Host request, file or model is run.
                memory.store.createNotesTaskFromMessage(
                  messageId: sourceId,
                  expectedSourceRev: 1,
                  itemNo: 0,
                  roomMode: 'light',
                  hostKey: 'ssh:r22-original-host',
                  agreement: notesAgreement(queue: true),
                );
              } else {
                memory.store.createReminderFromMessage(
                  messageId: sourceId,
                  expectedSourceRev: 1,
                  itemNo: 0,
                  roomMode: 'light',
                  executorId: 'installation-A',
                  reminder: CompanionReminderSpec(
                    text: '处理第$index件事',
                    localDate: '2026-11-25',
                    localTime: '08:00',
                    zoneId: 'Asia/Shanghai',
                    offsetSeconds: 28800,
                    epochMs: DateTime.utc(2026, 11, 25).millisecondsSinceEpoch,
                  ),
                );
              }
            }

            for (var index = 0; index < 100; index++) {
              addLater(index);
            }
            MemoryRow? other;
            MemoryRow? ambiguousSource;
            if (!hostWindow) {
              now++;
              const otherRaw = '2026-11-24 08:00 Asia/Shanghai提醒我带证件';
              await say(otherRaw, create('2026-11-24'));
              final source = memory.store.messages().singleWhere((row) => row['text'] == otherRaw);
              other = memory.store.taskForCommand(source['id']! as String, 0)!;
              expect(other['task_id'], isNot(id));
              final before = ledger();
              calls.clear();
              now++;
              // The model reads only the bounded list, which shows the newer
              // namesake and cannot prove the older one: it asks which (A1).
              const which = '你说的是哪一条？去「交代的事」里点给我看看。';
              Map<String, Object?>? listed;
              await say('取消带证件的提醒', [
                (_) => _reply2(calls: [('r22-list', 'task_status', <String, Object?>{})]),
                (body) {
                  listed = _toolResult2(body);
                  return _reply2(words: which);
                },
              ]);
              expect(listed!['limited'], isTrue);
              expect((listed!['tasks']! as List).cast<Map>().map((row) => row['task_id']), isNot(contains(id)));
              ambiguousSource = memory.store.messages().singleWhere((row) => row['text'] == '取消带证件的提醒');
              expect(memory.store.taskForCommand(ambiguousSource['id']! as String, 0), isNull);
              expect(ledger(), before);
              expect(calls.where((call) => const ['capabilities', 'resolve', 'wake'].contains(call.method)), isEmpty);
              expect(find.text(which), findsOneWidget);
            }
            final defaultRows = memory.store.tasks(sourceSessionId: room);
            expect(defaultRows, hasLength(100));
            expect(defaultRows.map((row) => row['task_id']), isNot(contains(id)));
            if (hostWindow) {
              expect(defaultRows.map((row) => row['kind']), everyElement('host.notes_to_todo'));
            }

            Future<void> openErrands() async {
              await tester.tap(find.byIcon(AppIcons.more));
              await tester.pumpAndSettle();
              await tester.ensureVisible(find.text('交代的事'));
              await tester.pumpAndSettle();
              await tester.tap(find.text('交代的事'));
              await tester.pumpAndSettle();
              expect(tester.widget<CompanionTasksPage>(find.byType(CompanionTasksPage)).taskId, isNull);
            }

            final beforeBrowse = ledger();
            calls.clear();
            await openErrands();
            expect(find.text('带证件'), hostWindow ? findsNothing : findsOneWidget);
            expect(find.text('更早的事'), findsOneWidget);
            expect(calls.map((call) => call.method), hostWindow ? isEmpty : ['capabilities']);
            expect(ledger(), beforeBrowse);

            Future<void> earlier() async {
              calls.clear();
              await tester.ensureVisible(find.text('更早的事'));
              await tester.pumpAndSettle();
              await tester.tap(find.text('更早的事'));
              await tester.pumpAndSettle();
              expect(calls.map((call) => call.method), ['capabilities']);
            }

            await earlier();
            expect(find.text('带证件'), hostWindow ? findsOneWidget : findsNWidgets(2));
            expect(find.text('更早的事'), findsNothing);
            expect(ledger(), beforeBrowse);
            calls.clear();
            await tester.tap(find.byIcon(AppIcons.refresh));
            await tester.pumpAndSettle();
            expect(find.text('带证件'), hostWindow ? findsOneWidget : findsNWidgets(2));
            expect(find.text('更早的事'), findsNothing);
            expect(calls.map((call) => call.method), ['capabilities']);
            expect(ledger(), beforeBrowse);

            if (hostWindow) {
              // At exactly the expanded limit there is no sentinel row to show.
              for (var index = 100; index < 199; index++) {
                addLater(index);
              }
              memory.changed();
              await tester.pump();
              expect(find.text('带证件'), findsOneWidget);
              expect(find.text('更早的事'), findsNothing);
              addLater(199);
              memory.changed();
              await tester.pump();
              expect(find.text('带证件'), findsNothing);
              expect(find.text('更早的事'), findsOneWidget);
              final afterInsertion = ledger();
              await earlier();
              expect(find.text('带证件'), findsOneWidget);
              expect(find.text('更早的事'), findsNothing);
              expect(ledger(), afterInsertion);
            } else {
              // The visible newer namesake is a different date. Returning from
              // its real detail route keeps the already expanded list.
              await tester.ensureVisible(find.text('带证件').first);
              await tester.pumpAndSettle();
              await tester.tap(find.text('带证件').first);
              await tester.pumpAndSettle();
              expect(tester.widget<CompanionTasksPage>(find.byType(CompanionTasksPage)).taskId, other!['task_id']);
              expect(find.textContaining('2026-11-24'), findsOneWidget);
              await tester.tap(find.byIcon(AppIcons.back));
              await tester.pumpAndSettle();
              expect(find.text('带证件'), findsNWidgets(2));
              expect(find.text('更早的事'), findsNothing);
            }

            final beforeDetail = ledger();
            calls.clear();
            await tester.ensureVisible(find.text('带证件').last);
            await tester.pumpAndSettle();
            await tester.tap(find.text('带证件').last);
            await tester.pumpAndSettle();
            expect(tester.widget<CompanionTasksPage>(find.byType(CompanionTasksPage)).taskId, id);
            expect(find.textContaining('2026-11-23'), findsOneWidget);
            expect(find.text('不用提醒了'), findsOneWidget);
            expect(memory.store.tasks(sourceSessionId: room).map((row) => row['task_id']), isNot(contains(id)));
            expect(calls.map((call) => call.method), ['capabilities']);
            expect(ledger(), beforeDetail);

            if (!hostWindow) {
              final receipts = memory.store.taskReceipts(id);
              final cancelStarted = Completer<void>();
              memory.receiptStarted = (_) => cancelStarted.complete();
              calls.clear();
              now++;
              await tester.tap(find.text('不用提醒了'));
              await settleMixed(tester, cancelStarted.future);
              memory.receiptStarted = null;
              await settleMixed(tester, memory.lastReceipt);
              await tester.pump();
              final stopped = memory.store.task(id)!;
              expect(stopped['task_rev'], 2);
              expect(stopped['operation'], 'cancel');
              expect(stopped['cancel_requested'], 1);
              expect(stopped['state'], 'queued', reason: 'The wake ACK does not prove that the alarm stopped');
              expect(stopped['source_message_id'], originalSource['id']);
              expect(stopped['source_session_id'], room);
              expect(stopped['command_message_id'], isNot(ambiguousSource!['id']));
              final source = memory.store.messages().singleWhere((row) => row['id'] == stopped['command_message_id']);
              expect(source['session_id'], room);
              expect(source['text'], '取消带证件的提醒');
              expect(memory.store.task(other!['task_id']! as String), other);
              expect(memory.store.taskReceipts(id), receipts);
              final afterCancel = ledger();
              expect(
                afterCancel[0].where((row) => row['task_id'] != id),
                beforeDetail[0].where((row) => row['task_id'] != id),
              );
              expect(afterCancel[1], hasLength(beforeDetail[1].length + 1));
              expect(afterCancel[1].where((row) => row['task_id'] != id || row['task_rev'] == 1), beforeDetail[1]);
              expect(afterCancel[2], beforeDetail[2]);
              expect(calls.where((call) => call.method == 'wake').single.arguments, {'taskId': id});
              expect(calls.where((call) => call.method == 'resolve'), isEmpty);
              expect(find.text('取消的要求已记下，还没确认这条提醒已撤下。'), findsOneWidget);
              expect(find.text('好，这条不提醒了。'), findsNothing);
            }
            expect(
              Map<String, Object?>.from(
                db.select('SELECT * FROM memory_messages WHERE id=?', [originalSource['id']]).single,
              ),
              sourceBefore,
            );
            // Only the scripted chat turns: the errands page itself never asks the model.
            expect(posts, hostWindow ? 2 : 6);
          },
        );
      }

      for (final rejectSource in [false, true]) {
        testWidgets('E actual Page keeps reminder lookup and factual clause identities, sourceFailure=$rejectSource', (
          tester,
        ) async {
          // A task reaches this room's result pills only while the app is in
          // the foreground (the Agent's task UI checks it, A1).
          final beforeLifecycle = tester.binding.lifecycleState;
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          addTearDown(() {
            if (beforeLifecycle != null) {
              tester.binding.handleAppLifecycleStateChanged(beforeLifecycle);
            } else {
              tester.binding.resetInternalState();
            }
          });
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
          final chats = <Map<String, Object?>>[];
          const rawText = '明天十四点提醒我带证件；帮我查今天青桥美术馆开不开，给我馆方公告；我午后练长笛';
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
              final sent = jsonDecode(request.body) as Map<String, Object?>;
              if (_isChat2(sent)) {
                chats.add(sent);
                // The phone model plans both clauses as its own tool calls in
                // one message; the factual clause is left to memory (A1).
                if (chats.length == 1) {
                  expect(jsonEncode(sent['messages']), contains(rawText));
                  return _reply2(
                    calls: [
                      (
                        'e-reminder',
                        'reminder',
                        {'operation': 'create', 'text': '带证件', 'localDate': '2026-11-22', 'localTime': '14:00'},
                      ),
                      (
                        'e-lookup',
                        'public_lookup',
                        {
                          'operation': 'create',
                          'placeName': '青桥美术馆',
                          'localDate': '2026-11-21',
                          'question': '今天开不开，给我馆方公告',
                        },
                      ),
                    ],
                  );
                }
                final results = _toolResults2(sent);
                expect(results.map((result) => result['tool_use_id']), ['e-reminder', 'e-lookup']);
                final lookup = (jsonDecode(results.last['content']! as String) as Map)['task']! as Map;
                // Her words come only from the lookup receipt the tool returned.
                return _reply2(words: '${(lookup['result'] as Map?)?['conclusion'] ?? '没查到。'}');
              }
              if (sent['system'] == companionMemoryExtractionPrompt) {
                return http.Response.bytes(
                  utf8.encode(_sse(['{"ops":[]}'])),
                  200,
                  headers: {'content-type': 'text/event-stream; charset=utf-8'},
                );
              }
              expect(sent['system'], companionLookupAnswerPrompt);
              final input = jsonDecode(((sent['messages']! as List)[0] as Map)['content'] as String) as Map;
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
          const raw = rawText;
          await tester.enterText(find.byType(TextField), raw);
          await tester.pump();
          await tester.tap(find.byIcon(AppIcons.send).last);
          await settleMixed(tester, clockRead.future);
          if (rejectSource) {
            await tester.pumpAndSettle();
            // Nothing classifies the line before the model now (A1): a failed source
            // commit is the room's ordinary send failure, with the draft kept.
            expect(find.text('这句话没送出去，要不要再说一次？'), findsOneWidget);
            expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
            expect(memory.store.messages(), isEmpty);
            expect(memory.store.tasks(), isEmpty);
            expect(posts, isEmpty);
            expect(calls.where((method) => method == 'resolve' || method == 'wake'), isEmpty);
            expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, raw);
          } else {
            await settleMixed(tester, answerSent.future);
            await _until2(
              tester,
              () => chats.length == 2 && !tester.widget<CompanionComposer>(find.byType(CompanionComposer)).running,
            );
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
          final chats = <Map<String, Object?>>[];
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
              final body = jsonDecode(request.body) as Map<String, Object?>;
              if (_isChat2(body)) {
                // The phone model plans each instruction as its own tool call
                // (A1); a cancel reads the original receipt before naming it.
                chats.add(body);
                final text = jsonEncode(body['messages']);
                if (!text.contains('取消青桥美术馆的查询')) {
                  return _reply2(
                    calls: [
                      (
                        'e2-lookup',
                        'public_lookup',
                        {
                          'operation': 'create',
                          'placeName': '青桥美术馆',
                          'localDate': '2026-11-21',
                          'question': '今天开不开，给我馆方公告',
                        },
                      ),
                    ],
                  );
                }
                final results = _toolResults2(body);
                if (results.isEmpty) {
                  return _reply2(calls: [('e2-list', 'task_status', <String, Object?>{})]);
                }
                final result = _toolResult2(body);
                if (result['tasks'] case final List listed) {
                  final task = listed.cast<Map>().singleWhere((row) => row['kind'] == 'public.lookup');
                  return _reply2(
                    calls: [
                      (
                        'e2-cancel',
                        'public_lookup',
                        {'operation': 'cancel', 'taskId': task['task_id'], 'expectedTaskRev': task['task_rev']},
                      ),
                    ],
                  );
                }
                return _reply2(words: '好，不查了。');
              }
              if (body['system'] == companionMemoryExtractionPrompt) {
                return http.Response.bytes(
                  utf8.encode(_sse(['{"ops":[]}'])),
                  200,
                  headers: {'content-type': 'text/event-stream; charset=utf-8'},
                );
              }
              expect(body['system'], companionLookupAnswerPrompt);
              answers++;
              final input = jsonDecode(((body['messages']! as List)[0] as Map)['content'] as String) as Map;
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
            await _until2(
              tester,
              () => chats.length == 4 && !tester.widget<CompanionComposer>(find.byType(CompanionComposer)).running,
            );
            await settleMixed(tester, memory.lastReceipt);
            expect(memory.store.lookupTask(initial['task_id']! as String)!['cancel_requested'], 1);
          } else {
            // Leave the room while the app keeps running: the process-level
            // agent and its phone client outlive the Page (A1). Tearing down
            // the whole ProviderScope would end the app, not just the visit.
            unawaited(
              tester
                  .state<NavigatorState>(find.byType(Navigator))
                  .pushReplacement(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('新的页面')))),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));
            await tester.pump(const Duration(milliseconds: 500));
            expect(find.byType(CompanionPage), findsNothing);
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
          // The interrupted first turn never continues with the late receipt.
          expect(chats, hasLength(after == 'cancel' ? 4 : 1));
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
            // The phone model plans each turn (A1): the first plans the
            // reminders as tool calls; a later "不用提醒了" reads the room's
            // receipts first. Every other request (memory upkeep) is refused.
            Map<String, Object?> reminder(String text) => {
              'operation': 'create',
              'text': text,
              'localDate': '2026-03-08',
              'localTime': '03:10',
              'zoneId': 'America/Los_Angeles',
            };
            Map<String, Object?>? listed;
            await openLight(
              tester,
              apiKey: 'sk-test',
              client: MockClient((request) async {
                final body = jsonDecode(request.body) as Map<String, Object?>;
                if (!_isChat2(body)) return http.Response('', 401);
                posts++;
                if (!jsonEncode(body['messages']).contains('不用提醒了')) {
                  return _reply2(
                    calls: [
                      ('d-keys', 'reminder', reminder('带钥匙')),
                      if (after == 'accepted then leave') ('d-papers', 'reminder', reminder('带证件')),
                    ],
                  );
                }
                if (_toolResults2(body).isEmpty) {
                  return _reply2(calls: [('d-list', 'task_status', <String, Object?>{})]);
                }
                listed = _toolResult2(body);
                return _reply2(words: '现在没有要撤的提醒。');
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
              // While her tool waits on the phone, any next line may go: it
              // retires the pending turn instead of waiting behind it (A1; the
              // old composer held ordinary text and let only controls through).
              await tester.enterText(find.byType(TextField), '我午后练长笛');
              await tester.pump();
              expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
              await tester.enterText(find.byType(TextField), '不用提醒了');
              await tester.pump();
              expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
              await tester.tap(find.byIcon(AppIcons.send).last);
              await settleMixed(tester, cancelledSource.future);
              memory.removeListener(changed);
              final cancellation = memory.lastReceipt;
              expect(identical(cancellation, operation), isFalse);
              await _until2(
                tester,
                () => listed != null && !tester.widget<CompanionComposer>(find.byType(CompanionComposer)).running,
              );
              await settleMixed(tester, memory.lastReceipt);
              expect(memory.store.messages().where((row) => row['text'] == '不用提醒了'), hasLength(1));
              // Nothing was accepted before the platform answered.
              expect(listed!['tasks'], isEmpty);
            } else {
              await tester.pumpWidget(const SizedBox());
              await tester.pumpWidget(_app(const Scaffold(body: Text('新的页面'))));
            }
            release.complete();
            await settleMixed(tester, operation);
            await tester.pump();
            expect(memory.store.tasks(), hasLength(accepted.length));
            expect(calls.where((call) => call.method == 'wake'), hasLength(accepted.length));
            // The retired first turn never continues once its platform call
            // returns: only the planning request, plus the cancel turn's two.
            expect(posts, after == 'cancel' ? 3 : 1);
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
          // The phone model plans both clauses as its own reminder calls (A1)
          // and then speaks only from the receipts the tools returned.
          Map<String, Object?> reminder(String text) => {
            'operation': 'create',
            'text': text,
            'localDate': '2026-03-08',
            'localTime': '03:10',
            'zoneId': 'America/Los_Angeles',
          };
          String line(Map<String, Object?> result) {
            final task = result['task']! as Map;
            final status = switch ((task['state'], task['wait_reason'])) {
              ('done', _) => '设好了，到点我叫你。',
              ('waiting', 'notifications_disabled') => '通知没开，这条还没设上。去系统设置里打开通知就好。',
              _ => '还没确认。',
            };
            return '${task['reminder_text']}：$status';
          }

          await openLight(
            tester,
            apiKey: 'sk-test',
            client: MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, Object?>;
              if (!_isChat2(body)) return http.Response('', 401);
              posts++;
              final results = _toolResults2(body);
              if (results.isEmpty) {
                return _reply2(
                  calls: [('d-keys', 'reminder', reminder('带钥匙')), ('d-papers', 'reminder', reminder('带证件'))],
                );
              }
              return _reply2(
                words: [
                  for (final result in results) line(jsonDecode(result['content']! as String) as Map<String, Object?>),
                ].join('\n'),
              );
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
            // Nothing classifies the line before the model now (A1): a failed source
            // commit is the room's ordinary send failure, with the draft kept.
            expect(find.text('这句话没送出去，要不要再说一次？'), findsOneWidget);
          } else {
            await settleMixed(tester, twoWakes.future);
            await _until2(
              tester,
              () => posts == 2 && !tester.widget<CompanionComposer>(find.byType(CompanionComposer)).running,
            );
            await settleMixed(tester, memory.lastReceipt);
            await tester.pump();
            final source = memory.store.messages().where((row) => row['role'] == 'user').single;
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
          // No model request before the source is committed; then one plan and one reply.
          expect(posts, rejectSource ? 0 : 2);
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
          // The chat page paces its sending and display with fake-clock timers.
          const beat = Duration(milliseconds: 50);
          await settleMixed(tester, storyEntered.future, step: beat);
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
          final events = await settleMixed(tester, done, step: beat);
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
        final memory = _RoomMemory2(
          CompanionMemoryStore(
            sqlite3.open('${root.path}/memory.sqlite'),
            nowMilliseconds: () => DateTime.now().millisecondsSinceEpoch,
          ),
          CompanionLocal.at(root),
        );
        phoneMemory = memory;
        final chats = <Map<String, Object?>>[];
        // The initial maintenance context; each continuation is another HTTP.
        final extracts = <Map<String, Object?>>[];
        var extractRequests = 0;
        late Completer<void> phoneEntered;
        const realName = '现实里，我的称呼是阿橙。';
        final phoneClient = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          final input = _maintenanceInput2(body);
          if (input != null) {
            expect(input['kind'], 'extract');
            extractRequests++;
            final results = _toolResults2(body);
            if (extractRequests == 1) {
              expect(results, isEmpty);
              extracts.add(input);
              final original = (input['sources']! as List).cast<Map>().where((row) => row['role'] == 'user').single;
              expect(original['text'], realName);
              return _reply2(
                calls: [
                  (
                    'fixture6-name',
                    'remember',
                    {
                      'source': original['id'],
                      'kind': 'fact',
                      'text': realName,
                      'keywords': ['称呼', '阿橙'],
                    },
                  ),
                ],
              );
            }
            expect(results.map((row) => row['tool_use_id']), ['fixture6-name']);
            expect((jsonDecode(results.single['content']! as String) as Map)['applied'], isTrue);
            return _reply2();
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
        // The visit the Page attached owns this memory work now (A1).
        expect(
          await tester.runAsync(() => memory.extract(memory.room!, forceTail: true)),
          CompanionMemoryWork.committed,
        );
        expect(extracts, hasLength(1));
        // One remember call, then the round after its result: two requests.
        expect(extractRequests, 2);
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
        expect((jsonDecode(block) as Map)['version'], 3);
        expect((jsonDecode(block) as Map)['items'], [
          {'id': card['id'], 'kind': 'fact', 'layer': 'card', 'collection': 'about_you', 'text': realName},
        ]);
        final phoneMessages = memory.store.messages();
        final phoneCards = memory.store.cards();
        final phoneReceipts = memory.store.requests();
        expect(jsonEncode(phoneMessages), isNot(contains('校长')));
        expect(phoneReceipts.where((row) => row['category'] == 'chat'), hasLength(2));
        final upkeep = phoneReceipts.where((row) => row['category'] == 'extract').toList();
        expect(upkeep, hasLength(2));
        expect(upkeep.map((row) => row['id']).toSet(), hasLength(2));
        expect(upkeep.map((row) => row['batch_id']).toSet(), hasLength(1));
        expect(upkeep.first['batch_id'], isA<String>());
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
            // Her model reads only this character's own sources: write them for
            // the character the Page actually mounted, from its own pack's key.
            final pack = tester.widget<CompanionPage>(find.byType(CompanionPage)).storeOverride!;
            final key = await settleMixed(tester, pack.characterKey());
            expect(key, isNotNull);
            final characterId = memory.store.ensureCompanionCharacter(sourceKey: key!)['id']! as String;
            Map<String, Object?> source(String id, String text, {String role = 'user'}) => memory.store.submitMessage(
              id: id,
              sessionId: memory.store.lightSessionId,
              text: text,
              role: role,
              saidAtUtc: DateTime.now().millisecondsSinceEpoch,
              offsetMinutes: 0,
              characterId: characterId,
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
            expect(memory.store.messages().singleWhere((row) => row['text'] == query)['character_id'], characterId);
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
        var extractRequests = 0;
        String? extractClaim;
        final client = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          posts.add(body);
          final input = _maintenanceInput2(body);
          final category = input == null ? 'chat' : input['kind']! as String;
          expect(category, isIn(['extract', 'organize', 'chat']));
          categories.add(category);
          final receipt = memory.store.requests().singleWhere(
            (row) => row['category'] == category && row['state'] == 'sent',
          );
          expect(receipt['sent_at_ms'], isNotNull);
          var answer = '可以，我们慢慢聊。';
          if (input != null) {
            // The maintenance claim, not the wire, carries the batch identity.
            expect(receipt['batch_id'], isA<String>());
            if (category == 'extract') {
              extractRequests++;
              extractClaim ??= receipt['batch_id']! as String;
              expect(receipt['batch_id'], extractClaim);
              final results = _toolResults2(body);
              if (extractRequests == 1) {
                expect(results, isEmpty);
                final sources = {
                  for (final row in (input['sources']! as List).cast<Map>())
                    if (row['role'] == 'user') row['id']: row['text'],
                };
                expect(sources, {'yogurt-a': '酸奶我只买原味。', 'yogurt-b': '我买酸奶一直只选原味。'});
                return _reply2(
                  calls: [
                    (
                      'fixture15-a',
                      'remember',
                      {
                        'source': 'yogurt-a',
                        'kind': 'preference',
                        'text': '你买酸奶只选原味。',
                        'keywords': ['酸奶'],
                      },
                    ),
                    (
                      'fixture15-b',
                      'remember',
                      {
                        'source': 'yogurt-b',
                        'kind': 'preference',
                        'text': '酸奶你只买原味的。',
                        'keywords': ['酸奶'],
                      },
                    ),
                  ],
                );
              }
              expect(results.map((row) => row['tool_use_id']), ['fixture15-a', 'fixture15-b']);
              expect((jsonDecode(results.last['content']! as String) as Map)['applied'], isTrue);
              return _reply2();
            }
            expect(receipt['batch_id'], isNot(extractClaim));
            expect(_toolResults2(body), isEmpty);
            expect(
              (input['cards']! as List).cast<Map>().map((row) => row['id']),
              unorderedEquals(memory.store.cards().map((row) => row['id'])),
            );
            expect(input['cards'] as List, hasLength(2));
            // A real organize request that changes nothing and ends.
            answer = '';
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
                  // The Messages stream names each content block; the phone
                  // agent reads tool blocks by this index (A1).
                  'index': 0,
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
        final owner = _RoomMemory2(
          CompanionMemoryStore(
            sqlite3.open('${root.path}/memory.sqlite'),
            nowMilliseconds: () => DateTime.now().millisecondsSinceEpoch,
          ),
          CompanionLocal.at(root),
        );
        addTearDown(owner.dispose);
        await openLight(
          tester,
          apiKey: 'sk-test',
          client: client,
          extra: [companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => owner)],
        );
        memory = await memoryOf(tester);
        await settleMixed(tester, memory.migrateLocal());
        // The visit the Page attached owns this memory work now (A1).
        final page = owner.room!;
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
        // Extraction remembers both (a request, then one after the results).
        expect(categories, ['extract', 'extract', 'organize']);
        expect(memory.store.cards(), hasLength(2));
        for (final (id, text, quote) in [
          ('yogurt-a', '你买酸奶只选原味。', '酸奶我只买原味。'),
          ('yogurt-b', '酸奶你只买原味的。', '我买酸奶一直只选原味。'),
        ]) {
          final proof = (memory.store.cards().singleWhere((row) => row['text'] == text)['evidence']! as List)
              .cast<Map>()
              .single;
          expect(proof['message_id'], id);
          expect(proof['quote'], quote);
        }
        final row = memory.store.cards().first;
        memory.store.setPinned(id: row['id']! as String, expectedRowRev: row['row_rev']! as int, pinned: true);
        memory.changed();
        final auxiliary = memory.store.requests();
        final extraction = auxiliary.where((row) => row['category'] == 'extract').toList();
        expect(extraction, hasLength(2));
        expect(extraction.map((row) => row['id']).toSet(), hasLength(2));
        expect(extraction.map((row) => row['batch_id']).toSet(), {extractClaim});
        expect(extraction.every((row) => row['state'] == 'finished' && row['terminal'] == 'complete'), isTrue);
        final organized = auxiliary.singleWhere((row) => row['category'] == 'organize');
        expect(organized['state'], 'finished');
        expect(organized['terminal'], 'complete');
        // The day's one organize opportunity is spent: the Store offers no new
        // claim (A2 reports that as idle), and nothing is reserved or sent.
        expect(await tester.runAsync(() => memory.consolidate(page)), CompanionMemoryWork.idle);
        expect(categories, ['extract', 'extract', 'organize']);
        expect(memory.store.requests(), auxiliary);
        expect(memory.store.messages(sessionId: memory.store.lightSessionId), isEmpty);
        // Within the same rolling window, an explicit ordinary composer send
        // still makes its own actual HTTP request and settles its own receipt.
        const query = '我想换个话题，今天过得怎么样？';
        await say(tester, query);
        expect(categories, ['extract', 'extract', 'organize', 'chat']);
        final content = (((posts.last['messages']! as List).last as Map)['content']! as List).cast<Map>();
        expect(content.first['text'], query);
        expect(find.text('可以，我们慢慢聊。'), findsOneWidget);
        final receipts = memory.store.requests();
        expect(receipts, hasLength(4));
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

        // The next line goes with what came before. Every explicit turn now
        // carries its own current clock and input window (A2), and only that: the earlier
        // turn's context is not replayed in the history.
        await tester.pump(const Duration(seconds: 12));
        await say(tester, '今天好累');
        expect(asked, hasLength(2));
        final next = asked.last['messages']! as List;
        expect(next.map((m) => (m as Map)['role']), ['user', 'assistant', 'user']);
        final latest = ((next.last as Map)['content']! as List).cast<Map>();
        expect(latest, hasLength(2));
        expect(latest.first['text'], '今天好累');
        final clock = RegExp(r'^<companion_context>(.*)</companion_context>$')
            .firstMatch(latest.last['text']! as String)!
            .group(1)!;
        expect(jsonDecode(clock), {'localTime': isA<String>(), 'window': 'room'});
        expect((next.first as Map)['content'], '你好');

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 20));
      });

      testWidgets('fixture 2 grouped Log names keep two submitted originals after reopening SQLite', (tester) async {
        final chats = <Map<String, Object?>>[];
        // The initial maintenance context; each continuation is another HTTP.
        final extracts = <Map<String, Object?>>[];
        var extractRequests = 0;
        final client = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          final input = _maintenanceInput2(body);
          if (input != null) {
            expect(input['kind'], 'extract');
            extractRequests++;
            final results = _toolResults2(body);
            if (extractRequests == 1) {
              expect(results, isEmpty);
              extracts.add(input);
              final sources = (input['sources']! as List).cast<Map>().where((row) => row['role'] == 'user').toList()
                ..sort((a, b) => (a['first_seq']! as int).compareTo(b['first_seq']! as int));
              expect(sources, hasLength(2));
              return _reply2(
                calls: [
                  for (var i = 0; i < sources.length; i++)
                    (
                      'fixture2-${i + 1}',
                      'remember',
                      {'source': sources[i]['id'], 'kind': 'fact', 'text': sources[i]['text']},
                    ),
                ],
              );
            }
            expect(results.map((row) => row['tool_use_id']), ['fixture2-1', 'fixture2-2']);
            expect((jsonDecode(results.last['content']! as String) as Map)['applied'], isTrue);
            return _reply2();
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
        // Both remembered in one round, then the round after the results.
        expect(extractRequests, 2);
        final sentSources = {
          for (final row in (extracts.single['sources']! as List).cast<Map>())
            if (row['role'] == 'user') row['id']: row,
        };
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
          // The maintenance wire carries each original's own UTC milliseconds.
          expect(sent['said_at_utc'], original['said_at_utc']);
          expect(sent['said_at_utc'], isA<int>());
          final proof = (cards.singleWhere((row) => row['text'] == original['text'])['evidence']! as List)
              .cast<Map>()
              .single;
          expect(proof['message_id'], original['id']);
          expect(proof['source_rev'], original['source_rev']);
          expect(proof['quote'], original['text']);
        }
        final after = reopened.store.requests();
        expect(after.where((row) => row['category'] == 'chat').toList(), receipts);
        // Two physical requests of one maintenance claim, each settled.
        final extraction = after.where((row) => row['category'] == 'extract').toList();
        expect(extraction, hasLength(2));
        expect(extraction.map((row) => row['id']).toSet(), hasLength(2));
        expect(extraction.first['batch_id'], isA<String>());
        expect(extraction.map((row) => row['batch_id']).toSet(), hasLength(1));
        expect(
          extraction.every(
            (row) => row['state'] == 'finished' && row['terminal'] == 'complete' && row['sent_at_ms'] != null,
          ),
          isTrue,
        );
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

        final memory = await memoryOf(tester);
        final before = tester.widget<CompanionLog>(log);
        memory.changed();
        await tester.pump();
        final after = tester.widget<CompanionLog>(log);
        expect(after, isNot(same(before)));
        expect(after.entries.first, same(before.entries.first));

        final saved = memory.store.messages().firstWhere((row) => row['text'] == '你好');
        memory.store.editMessage(
          id: saved['id']! as String,
          expectedSourceRev: saved['source_rev']! as int,
          text: '早上好',
        );
        memory.changed();
        await tester.pump();
        expect(find.descendant(of: log, matching: find.text('早上好')), findsOneWidget);
        expect(find.descendant(of: log, matching: find.text('你好')), findsNothing);

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
        // The Page sends the v3 block (layer, collection); the same two-card seed.
        final fixture = jsonDecode(
          File('../tooling/companion/fixtures/page-phone-context-v3.json').readAsStringSync(),
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
          final input = _maintenanceInput2(body);
          if (input != null) {
            expect(input['kind'], 'extract');
            expect(_toolResults2(body), isEmpty);
            extracts.add(input);
            // A complete maintenance turn that remembers nothing.
            return _reply2();
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
        // Her shown reply may come along as context; only one original is the person's.
        final sentSource = (extracts.single['sources']! as List).cast<Map>().singleWhere(
          (row) => row['role'] == 'user',
        );
        for (final field in ['id', 'first_seq', 'source_rev', 'offset_minutes', 'text']) {
          expect(sentSource[field], original[field], reason: field);
        }
        expect(sentSource['said_at_utc'], original['said_at_utc']);
        expect(sentSource['said_at_utc'], isA<int>());
        final after = reopened.store.requests();
        expect(after.where((row) => row['category'] == 'chat').toList(), receipts);
        final extract = after.singleWhere((row) => row['category'] == 'extract');
        expect(extract['batch_id'], isA<String>());
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

      for (final newerChat in [false, true]) {
        testWidgets(
          newerChat
              ? 'R21 late widget clear and EOF keep the newer Page reply and voice'
              : 'R21 memory control confirms locally while widget clear waits',
          (tester) async {
            const original = '我琴课一直在周四。';
            const correction = '琴课改成我琴课一直在周五。';
            const acknowledgment = '啊，是我记岔了。';
            const question = '刚才窗边那只橘猫怎么样？';
            const answer = '它还在窗边晒太阳呢。';
            const voiceChannel = MethodChannel('dsh/companion_voice');
            const widgetChannel = MethodChannel('dsh/companion_widget');
            final memory = _ReceiptMemory(
              CompanionMemoryStore(
                sqlite3.open('${root.path}/memory.sqlite'),
                nowMilliseconds: () => DateTime.now().millisecondsSinceEpoch,
              ),
              CompanionLocal.at(root),
            );
            final voiceCalls = <MethodCall>[];
            final widgetUpdates = <Map<String, Object?>>[];
            final voiceReady = Completer<void>();
            final answerSpoken = Completer<void>();
            final clearEntered = Completer<void>();
            final releaseClear = Completer<void>();
            final requestEntered = Completer<void>();
            final posts = <Map<String, Object?>>[];
            final destinations = <Uri>[];
            StreamController<List<int>>? body;
            Future<bool>? clearSettled;
            Future<void>? chatSettled;
            int? clearedRevision;
            // A correction is the model's own revise call now (A1), not a
            // local sentence parser: the control turn is one planning request
            // and one acknowledgment. A later question is held open here.
            // Memory upkeep requests are refused and not counted.
            final client = MockClient.streaming((request, bytes) async {
              final sent = jsonDecode(await bytes.transform(utf8.decoder).join()) as Map<String, Object?>;
              if (!_isChat2(sent)) return http.StreamedResponse(const Stream<List<int>>.empty(), 401);
              destinations.add(request.url);
              posts.add(sent);
              final reply = switch (posts.length) {
                1 => _reply2(
                  calls: [
                    ('r21-revise', 'revise', {'card': memory.store.cards().single['id'], 'text': '我琴课一直在周五。'}),
                  ],
                ),
                2 => _reply2(words: acknowledgment),
                _ => null,
              };
              if (reply != null) {
                return http.StreamedResponse(Stream.value(reply.bodyBytes), 200, headers: reply.headers);
              }
              final response = body = StreamController<List<int>>();
              if (!requestEntered.isCompleted) requestEntered.complete();
              return http.StreamedResponse(response.stream, 200, headers: {'content-type': 'text/event-stream'});
            });
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(voiceChannel, (call) async {
              voiceCalls.add(call);
              if (call.method == 'ready' && !voiceReady.isCompleted) voiceReady.complete();
              if (call.method == 'speak' && (call.arguments as Map)['text'] == answer && !answerSpoken.isCompleted) {
                answerSpoken.complete();
              }
              return switch (call.method) {
                'ready' || 'speak' => true,
                _ => null,
              };
            });
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(widgetChannel, (call) async {
              final values = Map<String, Object?>.from(call.arguments as Map);
              widgetUpdates.add(values);
              if (clearedRevision != null &&
                  values['memoryControlRevision'] == clearedRevision &&
                  values.containsKey('line') &&
                  values['line'] == null &&
                  values.containsKey('saidAt') &&
                  values['saidAt'] == null &&
                  !clearEntered.isCompleted) {
                clearEntered.complete();
                await releaseClear.future;
              }
              return true;
            });
            addTearDown(() async {
              if (!releaseClear.isCompleted) releaseClear.complete();
              if (clearSettled case final clearing?) await settleMixed(tester, clearing);
              await tester.pumpWidget(const SizedBox());
              final response = body;
              if (response != null && !response.isClosed) await settleMixed(tester, response.close());
              if (chatSettled case final chatting?) await settleMixed(tester, chatting);
              memory.dispose();
              client.close();
              await tester.pump(const Duration(seconds: 20));
              tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(voiceChannel, null);
              tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(widgetChannel, null);
            });
            memory.store.submitMessage(
              id: 'r21-lesson-original',
              sessionId: memory.store.lightSessionId,
              text: original,
              saidAtUtc: DateTime.now().millisecondsSinceEpoch,
              offsetMinutes: 0,
            );
            final batch = memory.store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
            final proposal = parseExtractionProposal(
              jsonEncode({
                'schema_version': 2,
                'batch_id': batch.id,
                'covered_message_ids': ['r21-lesson-original'],
                'completion': 'complete',
                'operations': [
                  {
                    'op': 'create',
                    'kind': 'fact',
                    'text': original,
                    'keywords': ['琴课'],
                    'evidence': [
                      {'message_id': 'r21-lesson-original', 'quote': original},
                    ],
                  },
                ],
              }),
              batch,
            );
            expect(memory.store.commitExtraction(batch, proposal), isTrue);
            await openLight(
              tester,
              apiKey: 'sk-test',
              client: client,
              extra: [
                companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory),
                companionEffectiveVoiceProvider.overrideWithValue(const CompanionVoiceSettings(on: true)),
              ],
            );
            expect(await memoryOf(tester), same(memory));
            await settleMixed(tester, voiceReady.future);
            final container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
            final widget = container.read(companionWidgetProvider);
            final before = memory.store.archive['control_revision']! as int;
            clearedRevision = before + 1;
            voiceCalls.clear();
            widgetUpdates.clear();

            await tester.enterText(find.byType(TextField), correction);
            await tester.pump();
            await tester.tap(find.byIcon(AppIcons.send).last);
            await settleMixed(tester, clearEntered.future);
            // Observe the same in-flight clear already started by the Page;
            // the real Widget queue stays held until its platform ACK arrives.
            final clearing = clearSettled = memory.clearWidget(widget);
            await tester.pump();
            // Her acknowledgment is the model's next reply, made after the
            // committed revision while the widget clear is still held.
            await _until2(
              tester,
              () =>
                  posts.length == 2 &&
                  !tester.widget<CompanionComposer>(find.byType(CompanionComposer)).running &&
                  voiceCalls.any((call) => call.method == 'speak'),
            );
            expect(releaseClear.isCompleted, isFalse);
            expect(memory.store.archive['control_revision'], clearedRevision);
            expect(memory.store.archive['widget_clear_pending'], 1);
            expect(memory.store.cards().single['text'], '我琴课一直在周五。');
            final controlSource = memory.store.messages().singleWhere((row) => row['text'] == correction);
            final proof = (memory.store.cards().single['evidence']! as List).cast<Map>().single;
            expect(proof['message_id'], controlSource['id']);
            expect(proof['source_rev'], controlSource['source_rev']);
            expect(proof['quote'], correction);
            expect(tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text, acknowledgment);
            expect(voiceCalls.where((call) => call.method == 'speak').map((call) => (call.arguments as Map)['text']), [
              acknowledgment,
            ]);
            // The correction is the model's own revise call; its result body
            // reports the committed card, and nothing else was asked of it.
            expect(posts, hasLength(2));
            expect(jsonEncode(posts.first['messages']), contains(correction));
            expect((posts.first['tools']! as List).cast<Map>().map((tool) => tool['name']), contains('revise'));
            final revised = _toolResult2(posts.last);
            expect(revised['applied'], isTrue);
            expect(revised['changedCardIds'], [memory.store.cards().single['id']]);
            expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);

            if (newerChat) {
              await tester.enterText(find.byType(TextField), question);
              await tester.pump();
              await tester.tap(find.byIcon(AppIcons.send).last);
              await settleMixed(tester, requestEntered.future);
              chatSettled = memory.lastReceipt;
              expect(posts, hasLength(3));
              expect(destinations.toSet().single.toString(), companionLightEndpoint);
              expect(jsonEncode(posts.last['messages']), contains(question));
              expect(memory.store.messages().singleWhere((row) => row['text'] == question)['role'], 'user');
              body!.add(utf8.encode(_sse([answer], end: false)));
              await settleMixed(tester, answerSpoken.future);
              await tester.pump();
              expect(tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text, answer);
              expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).running, isTrue);
              expect(
                voiceCalls.where((call) => call.method == 'speak').map((call) => (call.arguments as Map)['text']),
                [acknowledgment, answer],
              );
              final spoken = voiceCalls.lastWhere((call) => call.method == 'speak').arguments as Map;
              expect(spoken['flush'], isFalse, reason: 'the new streamed sentence uses the actual speaker queue');
              expect(memory.store.archive['widget_clear_pending'], 1);
              expect(releaseClear.isCompleted, isFalse);
            }

            final callsBeforeAck = List<MethodCall>.of(voiceCalls);
            releaseClear.complete();
            expect(await settleMixed(tester, clearing), isTrue);
            // Drain metadata behind the real queue without changing its line.
            expect(
              await settleMixed(
                tester,
                widget.update({
                  'memoryArchiveId': memory.store.archive['id'],
                  'memoryControlRevision': clearedRevision,
                }),
              ),
              isTrue,
            );
            await tester.pump();
            expect(memory.store.archive['widget_clear_pending'], 0);
            expect(
              tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text,
              newerChat ? answer : acknowledgment,
            );
            expect(voiceCalls, callsBeforeAck, reason: 'late clearing must not speak again or flush newer speech');

            if (newerChat) {
              body!.add(utf8.encode(_sse(const [])));
              await settleMixed(tester, body!.close());
              await settleMixed(tester, chatSettled!);
              await tester.pump();
              expect(tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text, answer);
              expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).running, isFalse);
              expect(
                voiceCalls,
                callsBeforeAck,
                reason: 'EOF must neither restore the old ACK nor repeat the new sentence',
              );
              final chatReceipts = memory.store.requests().where((row) => row['category'] == 'chat').toList();
              expect(chatReceipts, hasLength(3));
              expect(chatReceipts.every((row) => row['terminal'] == 'complete'), isTrue);
              expect(memory.store.messages().where((row) => row['role'] == 'assistant').map((row) => row['text']), [
                acknowledgment,
                answer,
              ]);
              expect(
                await settleMixed(
                  tester,
                  widget.update({
                    'memoryArchiveId': memory.store.archive['id'],
                    'memoryControlRevision': clearedRevision,
                  }),
                ),
                isTrue,
              );
              expect(widgetUpdates.where((value) => value['line'] != null).map((value) => value['line']), [answer]);
            } else {
              expect(posts, hasLength(2));
              expect(memory.store.requests().where((row) => row['category'] == 'chat'), hasLength(2));
              expect(widgetUpdates.where((value) => value['line'] != null), isEmpty);
            }
          },
        );
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
      // Page 挂载后才会连接记忆并开始恢复 owner。
      await settleMixed(tester, owner.ready);
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
