// Public attachment retry tests. The Agent, Ref, SQLite owner, wire decoder
// and reminder adapter are real. HTTP/native replies and the room UI port are
// explicit test boundaries; no Page, model service or native alarm is run.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_agent.dart';
import 'package:dsh_app/companion/companion_agent_task_ui.dart';
import 'package:dsh_app/companion/companion_host_tasks.dart';
import 'package:dsh_app/companion/companion_initiative.dart';
import 'package:dsh_app/companion/companion_initiative_owner.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_maps.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_memory_worker.dart';
import 'package:dsh_app/companion/companion_moves.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_public_lookup.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/companion/companion_widget.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

final _now = DateTime.utc(2026, 11, 22, 10).millisecondsSinceEpoch;
const _raw = '明天九点提醒我带伞。';
const _callId = 'actual-reminder-call';
const _preamble = '我来看看这条提醒。';
const _reminders = MethodChannel('dsh/companion_reminders');
const _widget = MethodChannel('dsh/companion_widget');

http.Response _message({
  bool tool = false,
  String? words,
  List<(String, String, Map<String, Object?>)> calls = const [],
}) {
  final pending = [
    if (tool)
      (
        _callId,
        'reminder',
        <String, Object?>{
          'operation': 'create',
          'text': '带伞',
          'localDate': '2026-11-23',
          'localTime': '09:00',
          'zoneId': 'Asia/Shanghai',
        },
      ),
    ...calls,
  ];
  var index = 0;
  final events = <Map<String, Object?>>[
    {
      'type': 'message_start',
      'message': {
        'id': 'controlled-message',
        'role': 'assistant',
        'content': <Object?>[],
        'usage': {'input_tokens': 12, 'output_tokens': 0},
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
    for (final (id, name, input) in pending) ...[
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
      'delta': {'stop_reason': pending.isEmpty ? 'end_turn' : 'tool_use'},
      'usage': {'input_tokens': 12, 'cache_read_input_tokens': 0, 'cache_creation_input_tokens': 0, 'output_tokens': 8},
    },
    {'type': 'message_stop'},
  ];
  return http.Response.bytes(
    utf8.encode([for (final event in events) 'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n'].join()),
    200,
    headers: {'content-type': 'text/event-stream; charset=utf-8'},
  );
}

Map _context(Map<String, Object?> request) {
  final texts = <String>[
    for (final message in (request['messages']! as List).cast<Map>())
      if (message['role'] == 'user' && message['content'] is List)
        for (final block in (message['content']! as List).cast<Map>())
          if (block['type'] == 'text') block['text']! as String,
  ];
  final text = texts.singleWhere((text) => text.startsWith('<companion_context>'));
  return jsonDecode(text.substring('<companion_context>'.length, text.length - '</companion_context>'.length)) as Map;
}

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

// These scenarios never ask for a directory, deadline, map, or foreground
// route. A request for one fails visibly instead of inventing a user choice.
class _TaskUi implements CompanionAgentTaskUi {
  _TaskUi(this.current, this.acceptedTasks);
  final bool Function() current;
  final List<MemoryRow> acceptedTasks;
  @override
  bool get isCurrent => current();
  @override
  bool get mapIsCurrent => current();
  @override
  CompanionAgentSelectionRoute? get onSelectionRoute => null;
  @override
  Future<String?> chooseDeadline(
    List<String> choices, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) => throw StateError('Unexpected deadline picker');
  @override
  Future<String?> chooseDirectory({
    required String kind,
    String? directoryHint,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) => throw StateError('Unexpected directory picker');
  @override
  Future<MemoryRow?> chooseSavedDirectory(
    List<MemoryRow> directories, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) => throw StateError('Unexpected saved directory picker');
  @override
  Future<MemoryRow?> chooseDrafts({
    required CompanionMemoryStore store,
    required String hostKey,
    required DshClient? client,
    required CompanionTasksCapability? capability,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
    String? originalStoreId,
  }) => throw StateError('Unexpected draft picker');
  @override
  Future<({List<MemoryRow> inputs, MemoryRow outputDirectory})?> chooseReceipts({
    required CompanionMemoryStore store,
    required String hostKey,
    required DshClient? client,
    required CompanionTasksCapability? capability,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
    String? originalStoreId,
    List<MemoryRow>? keptInputs,
    MemoryRow? keptOutput,
  }) => throw StateError('Unexpected receipt picker');
  @override
  Future<CompanionMapSpec?> chooseMap(
    CompanionMaps maps,
    String address, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) => throw StateError('Unexpected map picker');
  @override
  void accepted(MemoryRow task) => acceptedTasks.add(Map<String, Object?>.from(task));
  @override
  void startForeground(List<CompanionNotesForegroundCapture> captures, {required bool Function() isCurrent}) =>
      throw StateError('Unexpected foreground task');
}

class _RoomUi implements CompanionAgentRoomUi, CompanionInitiativeRoom {
  final failures = <({Object error, String? retry})>[];
  final commits = <String>[];
  final acceptedTasks = <MemoryRow>[];
  @override
  bool mounted = true;
  @override
  bool get stageReady => false;
  @override
  String get forgottenNotice => '已忘记。';
  @override
  CompanionInitiativeRoom get initiativeRoom => this;
  @override
  CompanionInitiativeView get initiativeView => const CompanionInitiativeView(
    visible: false,
    resumed: true,
    blocked: false,
    enabled: false,
    accessible: false,
    contextKey: 'retry-port',
  );
  @override
  bool get hasInvitation => false;
  @override
  CompanionAgentTaskUi tasks({required bool Function() isCurrent}) => _TaskUi(isCurrent, acceptedTasks);
  @override
  void committed(String raw) => commits.add(raw);
  @override
  void failed(Object error, {String? retry}) => failures.add((error: error, retry: retry));
  @override
  void detached() => mounted = false;
  @override
  void controlChanged({required bool own}) {}
  @override
  void connectionChanged() {}
  @override
  void widgetClearPending() {}
  @override
  void vitalsChanged(CompanionSnapshot snapshot) {}
  @override
  Future<void> greet(DateTime? lastVisit, bool Function() isCurrent) async {}
  @override
  bool presentFollowup(CompanionInitiativeDisplay display, String line) => false;
  @override
  void hideFollowup(String ticketId) {}
  @override
  bool canPresent(CompanionInitiativeTicket ticket) => false;
  @override
  void show(CompanionInitiativeDisplay display) {}
  @override
  void hide(String ticketId) {}
  @override
  void retime(String ticketId, int? expiresAtMono) {}
  @override
  void rest(CompanionInitiativeEffect intent) {}
}

class _Visit {
  _Visit(this.root, this.database, this.memory, this.replies);
  final Directory root;
  final Database database;
  final CompanionMemoryOwner memory;
  final List<http.Response> replies;
  final requests = <Map<String, Object?>>[];
  final native = <MethodCall>[];
  final ui = _RoomUi();
  ProviderContainer? _container;
  ProviderSubscription<CompanionAgent>? _keep;
  CompanionAgentAttachment? _attachment;
  ProviderContainer get container => _container!;
  CompanionAgentAttachment get attachment => _attachment!;
  late final CompanionAgent agent;
  int clockAt = _now;
  bool _closed = false;

  static Future<_Visit> open(
    List<http.Response> replies, {
    http.Response? Function(http.Request request)? auxiliary,
  }) async {
    final root = await Directory.systemTemp.createTemp('agent-public-visit-');
    final database = sqlite3.openInMemory();
    final memory = CompanionMemoryOwner(
      CompanionMemoryStore(database, nowMilliseconds: () => _now),
      CompanionLocal.at(root, nowMilliseconds: () => _now),
      nowMilliseconds: () => _now,
    );
    final visit = _Visit(root, database, memory, replies);
    addTearDown(visit.close);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_reminders, (call) async {
      visit.native.add(call);
      if (call.method == 'clock') return {'utcMs': visit.clockAt, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800};
      if (call.method == 'capabilities') return {'executorId': 'actual-phone'};
      if (call.method == 'resolve') {
        final input = call.arguments! as Map;
        return {
          'kind': 'unique',
          'moments': [
            {
              'epochMs':
                  DateTime.parse('${input['localDate']}T${input['localTime']}Z').millisecondsSinceEpoch - 28800000,
              'offsetSeconds': 28800,
            },
          ],
        };
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_widget, (_) async => true);
    // A real unconfigured worker keeps background extraction outside these
    // two explicit retry scenarios; no worker/controller subclass is installed.
    final background = CompanionLightMemoryTransport(apiKey: () => '');
    final provider = Provider<CompanionAgent>((ref) {
      final agent = CompanionAgent(
        ref: ref,
        memoryTransport: () => background,
        host: () => null,
        apiKey: () => 'controlled-test-key',
        client: () => MockClient((request) async {
          if (auxiliary?.call(request) case final response?) return response;
          visit.requests.add(Map<String, Object?>.from(jsonDecode(request.body) as Map));
          final index = visit.requests.length - 1;
          return index < replies.length ? replies[index] : http.Response('Unexpected extra model request', 503);
        }),
      );
      ref.onDispose(agent.dispose);
      return agent;
    });
    visit._container = ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(_Host.new),
        activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
        companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory),
        companionInitiativeClockProvider.overrideWithValue(
          () => CompanionInitiativeClock(wallMs: _now, monoMs: 0, offsetMinutes: 480),
        ),
      ],
    );
    // Keep the actual Ref dependencies active, rather than only reading a
    // non-auto-disposed object whose provider listeners may be paused.
    visit._keep = visit.container.listen(provider, (_, _) {});
    visit.agent = visit.container.read(provider);
    await visit.container.read(companionModeProvider.notifier).choose(CompanionMode.light);
    visit._attachment = visit.agent.attach(
      root: Future.value(root),
      character: const CompanionCharacter(name: '伙伴'),
      moves: const CompanionMoves(),
      ui: visit.ui,
      mapHandoff: CompanionMapHandoff(visit.container.read(companionMapsProvider)),
    );
    await visit.attachment.openMemory();
    return visit;
  }

  MemoryRow get userSource => memory.store.messages().singleWhere((row) => row['role'] == 'user');
  // Observation only. Every insertion/mutation occurs through the public
  // attachment and real tools, never a direct fixture SQL write.
  MemoryRow get turn => Map<String, Object?>.from(database.select('SELECT * FROM memory_agent_turns').single);
  int calls(String method) => native.where((call) => call.method == method).length;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _attachment?.detach();
    try {
      if (_container case final container?) await memory.clearWidget(container.read(companionWidgetProvider));
    } finally {
      _keep?.close();
      _container?.dispose();
      memory.dispose();
      try {
        await root.delete(recursive: true);
      } finally {
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(_reminders, null);
        messenger.setMockMethodCallHandler(_widget, null);
      }
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({'companion_mode': 'light', 'companion_initiative_enabled': false}),
  );

  test('public attachment retries a no-tool failure with the same source clock and open turn', () async {
    final visit = await _Visit.open([
      http.Response('Temporary model failure', 503),
      _message(tool: true),
      _message(words: '已记下这条提醒。'),
    ]);
    try {
      await visit.attachment.submit(_raw);
      final source = visit.userSource;
      final turn = visit.turn;
      expect(visit.requests, hasLength(1));
      expect(visit.attachment.error, isNotNull);
      expect(visit.attachment.text, isEmpty);
      expect(visit.ui.failures.single.retry, _raw);
      expect(turn['closed'], 0);
      expect(turn['changed_cards'], '[]');
      expect(visit.database.select('SELECT * FROM memory_agent_calls'), isEmpty);
      expect(visit.memory.store.tasks(), isEmpty);
      expect(source['said_at_utc'], _now);
      expect(source['zone_id'], 'Asia/Shanghai');
      expect(source['offset_seconds'], 28800);
      expect(visit.calls('clock'), 1);
      expect(_context(visit.requests.single)['localTime'], '2026-11-22T18:00+08:00');
      expect(_context(visit.requests.single).containsKey('originalMessage'), isFalse);

      visit.clockAt += 3600000;
      final retryStartedAt = DateTime.now().millisecondsSinceEpoch;
      await visit.attachment.submit(_raw);
      final retryFinishedAt = DateTime.now().millisecondsSinceEpoch;
      expect(visit.userSource, source);
      expect(visit.agent.sourceId, source['id']);
      expect(visit.turn['id'], turn['id']);
      expect(visit.turn['source_rev'], source['source_rev']);
      expect(visit.turn['closed'], 1);
      expect(visit.turn['changed_cards'], '[]');
      expect(visit.calls('clock'), 1);
      expect(visit.calls('wake'), 1);
      expect(visit.requests, hasLength(3));
      final retryContext = _context(visit.requests[1]);
      expect(retryContext['originalMessage'], {'localTime': '2026-11-22T18:00+08:00', 'zoneId': 'Asia/Shanghai'});
      expect(_context(visit.requests.last)['originalMessage'], retryContext['originalMessage']);
      final currentClock = DateTime.parse(retryContext['localTime']! as String).millisecondsSinceEpoch;
      // The wire clock has minute precision and must remain the current clock.
      expect(currentClock, inInclusiveRange(retryStartedAt - 60000, retryFinishedAt));
      expect(visit.attachment.error, isNull);
      expect(visit.attachment.text, '已记下这条提醒。');
      final task = visit.memory.store.tasks().single;
      expect(task['source_message_id'], source['id']);
      expect(task['source_session_id'], source['session_id']);
      expect(task['task_rev'], 1);
      expect(task['reminder_text'], '带伞');
      expect(visit.memory.store.taskForCommand(source['id']! as String, 0)!['task_id'], task['task_id']);
      final receipt = visit.memory.store.agentToolCall(turnId: turn['id']! as String, callId: _callId)!;
      expect(receipt.state, 'accepted');
      expect(receipt.taskId, task['task_id']);
      expect(receipt.itemNo, 0);
      expect(visit.ui.acceptedTasks, hasLength(1));
      final messages = visit.requests.last['messages']! as List;
      final results = (messages.last as Map)['content']! as List;
      expect((results.single as Map)['tool_use_id'], _callId);
      expect(jsonDecode((results.single as Map)['content']! as String), containsPair('accepted', true));
    } finally {
      await visit.close();
    }
  });

  test('public attachment does not replan a used turn after a preamble and failed continuation', () async {
    final visit = await _Visit.open([
      _message(tool: true, words: _preamble),
      http.Response('Continuation failed', 503),
    ]);
    try {
      await visit.attachment.submit(_raw);
      final source = visit.userSource;
      final turn = visit.turn;
      final task = visit.memory.store.tasks().single;
      final receipts = visit.memory.store.taskReceipts(task['task_id']! as String);
      final toolReceipt = visit.memory.store.agentToolCall(turnId: turn['id']! as String, callId: _callId)!;
      expect(visit.requests, hasLength(2));
      expect(visit.attachment.text, _preamble);
      expect(visit.attachment.error, isNotNull);
      expect(turn['closed'], 1);
      expect(toolReceipt.state, 'accepted');
      expect(toolReceipt.taskId, task['task_id']);
      expect(visit.calls('wake'), 1);
      expect(visit.calls('clock'), 1);
      expect(visit.ui.failures.single.retry, isNull);
      expect(
        visit.ui.failures.single.error,
        isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/agent-retry-closed'),
      );

      visit.clockAt += 3600000;
      await visit.attachment.submit(_raw);
      expect(visit.requests, hasLength(2));
      expect(visit.userSource, source);
      expect(visit.turn, turn);
      expect(visit.memory.store.tasks().single, task);
      expect(visit.memory.store.taskReceipts(task['task_id']! as String), receipts);
      expect(
        visit.memory.store.taskForCommand(source['id']! as String, toolReceipt.itemNo)!['task_id'],
        task['task_id'],
      );
      expect(visit.memory.store.agentToolCall(turnId: turn['id']! as String, callId: _callId)!.state, 'accepted');
      expect(visit.database.select('SELECT * FROM memory_agent_calls'), hasLength(1));
      expect(visit.calls('clock'), 1);
      expect(visit.calls('wake'), 1);
      expect(visit.ui.acceptedTasks, hasLength(1));
      expect(visit.ui.failures, hasLength(2));
      expect(visit.ui.failures.last.retry, isNull);
      expect(
        visit.ui.failures.last.error,
        isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/agent-retry-closed'),
      );
    } finally {
      await visit.close();
    }
  });

  for (final sameBatch in [true, false]) {
    test(
      'public attachment keeps reminder and memory outcomes across a control commit: sameBatch=$sameBatch',
      () async {
        const reminder = (
          'kept-reminder',
          'reminder',
          <String, Object?>{
            'operation': 'create',
            'text': '带伞',
            'localDate': '2026-11-23',
            'localTime': '09:00',
            'zoneId': 'Asia/Shanghai',
          },
        );
        const remember = (
          'kept-preference',
          'remember',
          <String, Object?>{
            'kind': 'preference',
            'text': '我喜欢简短回答。',
            'keywords': ['简短'],
          },
        );
        final visit = await _Visit.open([
          if (sameBatch)
            _message(calls: [reminder, remember])
          else ...[
            _message(calls: [reminder]),
            _message(calls: [remember]),
          ],
          _message(words: '提醒已记下，也记住了回答偏好。'),
        ]);
        try {
          await visit.attachment.submit('明天九点提醒我带伞；我喜欢简短回答。');
          expect(visit.attachment.error, isNull);
          final task = visit.memory.store.tasks().single;
          final card = visit.memory.store.cards().single;
          expect(task['reminder_text'], '带伞');
          expect(card['text'], '我喜欢简短回答。');
          expect(visit.calls('wake'), 1);
          final resultRows = <Map>[
            for (final message in (visit.requests.last['messages']! as List).cast<Map>())
              if (message['role'] == 'user' && message['content'] is List)
                for (final row in (message['content']! as List).cast<Map>())
                  if (row['type'] == 'tool_result') row,
          ];
          expect(resultRows.map((row) => row['tool_use_id']), ['kept-reminder', 'kept-preference']);
          final reminded = jsonDecode(resultRows.first['content']! as String) as Map;
          final remembered = jsonDecode(resultRows.last['content']! as String) as Map;
          expect(reminded['accepted'], isTrue);
          expect(remembered['applied'], isTrue);
          expect(remembered['targetId'], card['id']);
          final retainedTask = reminded['task'] as Map;
          for (final key in [
            'task_id',
            'task_rev',
            'kind',
            'state',
            'local_date',
            'local_time',
            'zone_id',
            'epoch_ms',
          ]) {
            expect(retainedTask[key], task[key], reason: key);
          }
          expect(retainedTask['reminder_text'], task['reminder_text']);
          expect(visit.requests, hasLength(sameBatch ? 2 : 3));
          expect(visit.memory.store.requests(), hasLength(visit.requests.length));
          expect(
            visit.memory.store.requests().every((row) => row['state'] == 'finished' && row['terminal'] == 'complete'),
            isTrue,
          );
        } finally {
          await visit.close();
        }
      },
    );
  }

  test('public attachment keeps the actual lookup report after adding a new memory', () async {
    final lookupPaths = <String>[];
    late final _Visit visit;
    http.Response jsonResponse(Object value) => http.Response.bytes(
      utf8.encode(jsonEncode(value)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    visit = await _Visit.open(
      [
        _message(
          calls: [
            (
              'actual-lookup',
              'public_lookup',
              {'operation': 'create', 'placeName': '青桥美术馆', 'localDate': '2026-11-21', 'question': '青桥美术馆是否开放？'},
            ),
            (
              'new-preference',
              'remember',
              {
                'kind': 'preference',
                'text': '我喜欢简短回答。',
                'keywords': ['简短'],
              },
            ),
          ],
        ),
        _message(words: '所问日期闭馆；也记住了你的回答偏好。'),
      ],
      auxiliary: (request) {
        if (request.url.path.endsWith('/search')) {
          lookupPaths.add(request.url.path);
          return jsonResponse({
            'results': [
              {'url': 'https://museum.example/notice', 'title': '青桥美术馆馆方公告', 'snippet': '搜索摘要', 'date': '2026-11-20'},
            ],
          });
        }
        if (request.url.path.endsWith('/fetch')) {
          lookupPaths.add(request.url.path);
          return jsonResponse({'title': '馆方公告', 'content': '2026-11-21临时闭馆一天。'});
        }
        final body = jsonDecode(request.body) as Map;
        if (body['system'] != companionLookupAnswerPrompt) return null;
        lookupPaths.add(request.url.path);
        final task = visit.memory.store.tasks().single;
        final fetch = visit.memory.store
            .lookupAttempts(task['task_id']! as String)
            .singleWhere((row) => row['kind'] == 'fetch');
        return _message(
          words: jsonEncode({
            'status': 'done',
            'conclusion': '所问日期临时闭馆。',
            'applicable_date': '2026-11-21',
            'evidence': [
              {'fetchRequestId': fetch['request_id'], 'quote': '2026-11-21临时闭馆一天。'},
            ],
          }),
        );
      },
    );
    try {
      await visit.attachment.submit('查青桥美术馆昨天是否开放；我喜欢简短回答。');
      expect(visit.attachment.error, isNull);
      expect(visit.requests, hasLength(2));
      expect(lookupPaths, ['/v1/tools/search', '/v1/tools/fetch', '/anthropic/v1/messages']);
      final task = visit.memory.store.lookupTask(visit.memory.store.tasks().single['task_id']! as String)!;
      expect(task['state'], 'done');
      expect(visit.memory.store.cards().single['text'], '我喜欢简短回答。');
      final results = (((visit.requests.last['messages']! as List).last as Map)['content']! as List).cast<Map>();
      expect(results.map((row) => row['tool_use_id']), ['actual-lookup', 'new-preference']);
      final lookup = jsonDecode(results.first['content']! as String) as Map;
      expect(lookup['accepted'], isTrue);
      expect((lookup['task']! as Map)['task_id'], task['task_id']);
      expect((lookup['task']! as Map)['result'], task['result']);
      expect(((lookup['task']! as Map)['result']! as Map)['evidence'], isNotEmpty);
      expect(jsonEncode(lookup), contains('所问日期临时闭馆。'));
      expect((jsonDecode(results.last['content']! as String) as Map)['applied'], isTrue);
      expect(visit.memory.store.lookupAttempts(task['task_id']! as String), hasLength(3));
    } finally {
      await visit.close();
    }
  });

  test('public attachment keeps outcome IDs but retires recalled text and old revise arguments after forget', () async {
    const id = '11111111-1111-4111-8111-111111111111';
    const oldText = '凭证的旧私密正文：BLUE-ORIGINAL。';
    const newText = '凭证的改后私密正文：GREEN-REVISED。';
    final visit = await _Visit.open([
      _message(
        calls: [
          ('private-recall', 'recall', {'query': '凭证'}),
        ],
      ),
      _message(
        calls: [
          (
            'private-revise',
            'revise',
            {
              'card': id,
              'text': newText,
              'keywords': ['凭证'],
            },
          ),
        ],
      ),
      _message(
        calls: [
          ('private-forget', 'forget', {'card': id}),
        ],
      ),
      _message(words: '已经处理好了。'),
    ]);
    try {
      visit.memory.store.saveManual(
        const CompanionMemory(id: id, text: oldText, keywords: ['凭证']),
        expectedRowRev: null,
        currentValueChange: true,
        realityKnown: true,
      );
      visit.memory.changed();
      await visit.attachment.submit('请查看凭证，改正后忘掉。');
      expect(visit.attachment.error, isNull);
      expect(visit.requests, hasLength(4));
      expect(jsonEncode(visit.requests[1]), contains(oldText));
      expect(jsonEncode(visit.requests[2]), isNot(contains(oldText)));
      expect(jsonEncode(visit.requests[2]), contains(newText));
      final finalBody = jsonEncode(visit.requests.last);
      expect(finalBody, isNot(contains(oldText)));
      expect(finalBody, isNot(contains(newText)));
      expect(visit.memory.store.cards(), isEmpty);
      final results = <Map>[
        for (final message in (visit.requests.last['messages']! as List).cast<Map>())
          if (message['role'] == 'user' && message['content'] is List)
            for (final row in (message['content']! as List).cast<Map>())
              if (row['type'] == 'tool_result') row,
      ];
      expect(results.map((row) => row['tool_use_id']), ['private-recall', 'private-revise', 'private-forget']);
      for (final result in results) {
        expect((jsonDecode(result['content']! as String) as Map)['applied'], isTrue);
      }
      for (final message in (visit.requests.last['messages']! as List).cast<Map>()) {
        if (message['role'] != 'assistant' || message['content'] is! List) continue;
        for (final block in (message['content']! as List).cast<Map>()) {
          if (block['type'] == 'tool_use') {
            expect(block['input'], {'_retired_after_memory_change': true});
          }
        }
      }
    } finally {
      await visit.close();
    }
  });

  test('two nearby public submissions each send their actual date time offset and zone', () async {
    final visit = await _Visit.open([_message(words: '我在。'), _message(words: '明天是二十三日。')]);
    try {
      await visit.attachment.submit('今天你好。');
      visit.clockAt += const Duration(minutes: 5).inMilliseconds;
      await visit.attachment.submit('明天是哪一天？');
      expect(visit.requests, hasLength(2));
      expect(_context(visit.requests.first)['localTime'], '2026-11-22T18:00+08:00');
      expect(_context(visit.requests.last)['localTime'], '2026-11-22T18:05+08:00');
      expect(_context(visit.requests.first)['zoneId'], 'Asia/Shanghai');
      expect(_context(visit.requests.last)['zoneId'], 'Asia/Shanghai');
      expect(visit.calls('clock'), 2);
      final sources = visit.memory.store.messages().where((row) => row['role'] == 'user').toList();
      expect(sources.map((row) => row['said_at_utc']), [_now, _now + 300000]);
      expect(sources.map((row) => row['text']), ['今天你好。', '明天是哪一天？']);
    } finally {
      await visit.close();
    }
  });
}
