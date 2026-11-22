import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_agent_task_tools.dart';
import 'package:dsh_app/companion/companion_agent_task_ui.dart';
import 'package:dsh_app/companion/companion_agent_tools.dart';
import 'package:dsh_app/companion/companion_host_tasks.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_maps.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_reminder.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/companion_notes_peer.dart';
import '../support/companion_receipts_peer.dart' show receiptsCapability;

final _now = DateTime.utc(2026, 11, 21, 10).millisecondsSinceEpoch;

class _Ui implements CompanionAgentTaskUi {
  bool current = true;
  final routes = <CompanionAgentSelectionRoute?>[];
  final acceptedTasks = <MemoryRow>[];
  final foregroundBatches = <List<CompanionNotesForegroundCapture>>[];
  final foregroundCurrent = <bool>[];
  Future<void> Function()? beforeDirectory;
  MemoryRow? offlineDrafts;
  ({List<MemoryRow> inputs, MemoryRow outputDirectory})? offlineReceipts;
  final offlinePickers = <String>[];
  var directories = 0;
  @override
  bool get isCurrent => current;
  @override
  bool get mapIsCurrent => current;
  @override
  // ignore: prefer_function_declarations_over_variables
  late final CompanionAgentSelectionRoute onSelectionRoute = (_, _) {};
  @override
  Future<String?> chooseDeadline(
    List<String> choices, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async {
    routes.add(onRouteChanged);
    return choices.first;
  }

  @override
  Future<String?> chooseDirectory({
    required String kind,
    String? directoryHint,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async {
    routes.add(onRouteChanged);
    directories++;
    await beforeDirectory?.call();
    return '/person-selected/$directories';
  }

  @override
  Future<MemoryRow?> chooseSavedDirectory(
    List<MemoryRow> directories, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async {
    routes.add(onRouteChanged);
    offlinePickers.add('directory');
    return directories.single;
  }

  @override
  Future<MemoryRow?> chooseDrafts({
    required CompanionMemoryStore store,
    required String hostKey,
    required DshClient? client,
    required CompanionTasksCapability? capability,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
    String? originalStoreId,
  }) async {
    routes.add(onRouteChanged);
    if (client == null) {
      expect(capability, isNull);
      offlinePickers.add('drafts');
      return offlineDrafts;
    }
    final connected = client;
    final supported = capability!;
    final folder = await connected.bindCompanionNotesDirectory(supported, '/person-selected/drafts');
    return {
      for (final side in ['a', 'b'])
        side: await connected.bindCompanionDraftInput(
          supported,
          folderRef: folder['folderRef']! as String,
          name: '$side.txt',
        ),
    };
  }

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
  }) async {
    routes.add(onRouteChanged);
    if (client == null) {
      expect(capability, isNull);
      offlinePickers.add('receipts');
      return offlineReceipts;
    }
    final connected = client;
    final supported = capability!;
    final folder = await connected.bindCompanionNotesDirectory(supported, '/person-selected/receipts');
    final inputs = <MemoryRow>[
      for (var index = 0; index < 4; index++)
        await connected.bindCompanionReceiptInput(
          supported,
          folderRef: folder['folderRef']! as String,
          name: 'receipt-$index.txt',
        ),
    ];
    final output = await connected.bindCompanionNotesDirectory(supported, '/person-selected/output');
    return (inputs: inputs, outputDirectory: output);
  }

  @override
  Future<CompanionMapSpec?> chooseMap(
    CompanionMaps maps,
    String address, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async {
    routes.add(onRouteChanged);
    return CompanionMapSpec(address: address, targetKind: 'choice');
  }

  @override
  void accepted(MemoryRow task) => acceptedTasks.add(Map<String, Object?>.from(task));
  @override
  void startForeground(List<CompanionNotesForegroundCapture> captures, {required bool Function() isCurrent}) {
    foregroundBatches.add(List.of(captures));
    foregroundCurrent.add(isCurrent());
  }
}

class _Archive {
  _Archive(this.root) {
    memory = CompanionMemoryOwner(
      CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => _now, createId: nextId),
      CompanionLocal.at(root, nowMilliseconds: () => _now),
      nowMilliseconds: () => _now,
    );
    source = memory.store.submitMessage(
      id: 'actual-user-source',
      sessionId: memory.store.lightSessionId,
      text: 'Bring 带伞 and 带钥匙; 青桥美术馆 needs checking. Address: 上海市黄浦区人民大道 201 号. Please use the selected originals.',
      saidAtUtc: _now,
      offsetMinutes: 480,
      zoneId: 'Asia/Shanghai',
      offsetSeconds: 28800,
    );
    memoryTools = CompanionAgentMemoryTools(
      memory: memory,
      source: source,
      isCurrent: () => current,
      forgottenNotice: '已忘记。',
      onCommitted: ({required memory, required sourceId, required beforeRevision, required revision}) {},
    );
  }
  final Directory root;
  late final CompanionMemoryOwner memory;
  late final MemoryRow source;
  late final CompanionAgentMemoryTools memoryTools;
  final _Ui ui = _Ui();
  final reminders = const CompanionReminders();
  final maps = const CompanionMaps();
  late final handoff = CompanionMapHandoff(maps);
  bool current = true;
  int sequence = 0;
  final tools = <CompanionAgentTaskTools>[];
  String nextId() => '00000000-0000-4000-8000-${(++sequence).toString().padLeft(12, '0')}';
  CompanionAgentTaskTools bind({String mode = 'full', CompanionAgentTaskHost? host, http.Client Function()? client}) {
    final bound = CompanionAgentTaskTools(
      memoryTools: memoryTools,
      source: source,
      roomMode: mode,
      reminders: reminders,
      maps: maps,
      mapHandoff: handoff,
      ui: ui,
      apiKey: 'actual-test-key',
      lightClientFactory: client ?? () => MockClient((_) async => http.Response('not selected', 503)),
      requestId: nextId,
      host: host,
    );
    tools.add(bound);
    return bound;
  }

  Future<void> close() async {
    ui.current = false;
    for (final tool in tools) {
      tool.close();
    }
    memoryTools.close();
    memory.dispose();
    await root.delete(recursive: true);
  }
}

MemoryRow _body(CompanionAgentToolResult result) => Map<String, Object?>.from(jsonDecode(result.content) as Map);
http.Response _json(Object? data) => http.Response.bytes(
  utf8.encode(jsonEncode(data)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
http.Response _answer(Object? data) => http.Response.bytes(
  utf8.encode(
    [
      {
        'type': 'message_start',
        'message': {
          'usage': {'input_tokens': 9, 'output_tokens': 1},
        },
      },
      {
        'type': 'content_block_delta',
        'delta': {'type': 'text_delta', 'text': jsonEncode(data)},
      },
      {
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
        'usage': {
          'input_tokens': 40,
          'cache_read_input_tokens': 0,
          'cache_creation_input_tokens': 0,
          'output_tokens': 50,
        },
      },
      {'type': 'message_stop'},
    ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
  ),
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const reminderChannel = MethodChannel('dsh/companion_reminders');
  const mapChannel = MethodChannel('dsh/companion_maps');
  late _Archive archive;
  final nativeCalls = <MethodCall>[];
  Future<Object?> defaultReminder(MethodCall call) async {
    nativeCalls.add(call);
    if (call.method == 'capabilities') return {'executorId': 'actual-phone'};
    if (call.method == 'resolve') {
      final args = call.arguments! as Map;
      return {
        'kind': 'unique',
        'moments': [
          {
            'epochMs': DateTime.parse('${args['localDate']}T${args['localTime']}Z').millisecondsSinceEpoch - 28800000,
            'offsetSeconds': 28800,
          },
        ],
      };
    }
    return null;
  }

  setUp(() async {
    nativeCalls.clear();
    archive = _Archive(await Directory.systemTemp.createTemp('agent-real-task-tools-'));
    messenger.setMockMethodCallHandler(reminderChannel, defaultReminder);
    messenger.setMockMethodCallHandler(mapChannel, (call) async {
      nativeCalls.add(call);
      if (call.method == 'capabilities') return {'executorId': 'actual-phone'};
      if (call.method == 'openScope') return {'scopeId': 'original-scope'};
      return null;
    });
  });
  tearDown(() async {
    await archive.close();
    messenger.setMockMethodCallHandler(reminderChannel, null);
    messenger.setMockMethodCallHandler(mapChannel, null);
  });

  test(
    'structured reminder calls retain one command across live replay and allocate the next actual ordinal',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      messenger.setMockMethodCallHandler(reminderChannel, (call) async {
        if (call.method == 'resolve' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
        return defaultReminder(call);
      });
      final tools = archive.bind();
      expect(tools.bindings.map((entry) => entry.definition.name), [
        'task_status',
        'reminder',
        'public_lookup',
        'map_open',
      ]);
      const call = CompanionAgentToolCall(
        id: 'first',
        name: 'reminder',
        input: {'operation': 'create', 'text': '带伞', 'localDate': '2026-11-22', 'localTime': '08:00'},
      );
      final first = tools.execute(call);
      try {
        await entered.future;
        final repeat = tools.execute(call);
        final conflict = await tools.execute(
          const CompanionAgentToolCall(
            id: 'first',
            name: 'reminder',
            input: {'operation': 'create', 'text': '带钥匙', 'localDate': '2026-11-22', 'localTime': '08:00'},
          ),
        );
        expect(conflict.isError, isTrue);
        expect(archive.memory.store.tasks(), isEmpty);
        release.complete();
        final result = await first;
        expect(_body(await repeat), _body(result));
        final saved = archive.memory.store.tasks().single;
        expect(saved['room_mode'], 'light');
        expect(saved['host_key'], isNull);
        expect(saved['source_session_id'], archive.source['session_id']);
        expect(saved['reminder_text'], '带伞');
        expect(saved['zone_id'], 'Asia/Shanghai');
        expect(nativeCalls.where((entry) => entry.method == 'wake'), hasLength(1));
        expect(_body(await tools.execute(call)), containsPair('replayed', true));
        expect(nativeCalls.where((entry) => entry.method == 'wake'), hasLength(1));
        await tools.execute(
          const CompanionAgentToolCall(
            id: 'second-round',
            name: 'reminder',
            input: {'operation': 'create', 'text': '带钥匙', 'localDate': '2026-11-22', 'localTime': '09:00'},
          ),
        );
        final firstReceipt = archive.memory.store.agentToolCall(turnId: archive.memoryTools.turnId, callId: 'first')!;
        final secondReceipt = archive.memory.store.agentToolCall(
          turnId: archive.memoryTools.turnId,
          callId: 'second-round',
        )!;
        expect(firstReceipt.state, 'accepted');
        expect(secondReceipt.state, 'accepted');
        expect(secondReceipt.itemNo, greaterThan(firstReceipt.itemNo));
        expect(
          archive.memory.store.taskForCommand('actual-user-source', firstReceipt.itemNo)!['task_id'],
          saved['task_id'],
        );
        expect(archive.memory.store.tasks(), hasLength(2));
        final amended = await tools.execute(
          CompanionAgentToolCall(
            id: 'amend-original',
            name: 'reminder',
            input: {'operation': 'amend', 'taskId': saved['task_id'], 'expectedTaskRev': 1, 'localTime': '10:00'},
          ),
        );
        expect((_body(amended)['task']! as Map)['task_rev'], 2);
        expect(archive.memory.store.task(saved['task_id']! as String)!['local_time'], '10:00');
        final stale = await tools.execute(
          CompanionAgentToolCall(
            id: 'stale-revision',
            name: 'reminder',
            input: {'operation': 'cancel', 'taskId': saved['task_id'], 'expectedTaskRev': 1},
          ),
        );
        expect(_body(stale)['code'], 'read_the_original_task_first');
        expect(archive.memory.store.task(saved['task_id']! as String)!['cancel_requested'], 0);
        final cancelled = await tools.execute(
          CompanionAgentToolCall(
            id: 'cancel-original',
            name: 'reminder',
            input: {'operation': 'cancel', 'taskId': saved['task_id'], 'expectedTaskRev': 2},
          ),
        );
        expect((_body(cancelled)['task']! as Map)['cancel_requested'], 1);
        final other = archive.memory.store.taskForCommand('actual-user-source', secondReceipt.itemNo)!;
        expect(other['task_rev'], 1);
        expect(other['cancel_requested'], 0);
      } finally {
        if (!release.isCompleted) release.complete();
        await first;
      }
    },
  );

  test('a reminder wording amendment preserves its selected repeated-time occurrence', () async {
    messenger.setMockMethodCallHandler(reminderChannel, (call) async {
      if (call.method != 'resolve') return defaultReminder(call);
      nativeCalls.add(call);
      final args = call.arguments! as Map;
      expect(args['zoneId'], 'America/New_York');
      final selected = args['selectedOffsetSeconds'] as int?;
      final offsets = selected == null ? [-14400, -18000] : [selected];
      return {
        'kind': selected == null ? 'overlap' : 'unique',
        'moments': [
          for (final offset in offsets)
            {
              'epochMs':
                  DateTime.parse('${args['localDate']}T${args['localTime']}Z').millisecondsSinceEpoch - offset * 1000,
              'offsetSeconds': offset,
            },
        ],
      };
    });
    final tools = archive.bind();
    final created = await tools.execute(
      const CompanionAgentToolCall(
        id: 'overlap-create',
        name: 'reminder',
        input: {
          'operation': 'create',
          'text': '带伞',
          'localDate': '2027-11-07',
          'localTime': '01:30',
          'zoneId': 'America/New_York',
          'selectedOffsetSeconds': -18000,
        },
      ),
    );
    expect(created.isError, isFalse);
    final before = archive.memory.store.tasks().single;
    final id = before['task_id']! as String;
    expect(before['state'], 'queued');
    expect(before['offset_seconds'], -18000);
    expect(before['epoch_ms'], DateTime.utc(2027, 11, 7, 6, 30).millisecondsSinceEpoch);
    final wording = CompanionAgentToolCall(
      id: 'overlap-wording',
      name: 'reminder',
      input: {'operation': 'amend', 'taskId': id, 'expectedTaskRev': 1, 'text': '带钥匙'},
    );
    final amended = await tools.execute(wording);
    expect(amended.isError, isFalse);
    expect(amended.externalWebContent, isFalse);
    expect(_body(amended)['receiptError'], isNull);
    final after = archive.memory.store.task(id)!;
    expect(after['task_rev'], 2);
    expect(after['reminder_text'], '带钥匙');
    expect(after['state'], 'queued');
    expect(after['wait_reason'], isNull);
    for (final field in ['local_date', 'local_time', 'zone_id', 'offset_seconds', 'epoch_ms']) {
      expect(after[field], before[field], reason: 'Wording does not choose another occurrence: $field');
    }
    expect(nativeCalls.where((call) => call.method == 'resolve'), hasLength(1));
    expect(nativeCalls.where((call) => call.method == 'wake'), hasLength(2));
    expect(
      archive.memory.store.agentToolCall(turnId: archive.memoryTools.turnId, callId: wording.id)!.state,
      'accepted',
    );
    expect(_body(await tools.execute(wording))['replayed'], isTrue);
    expect(archive.memory.store.task(id)!['task_rev'], 2);
    expect(nativeCalls.where((call) => call.method == 'wake'), hasLength(2));
    // Selecting the other occurrence is a time edit and must resolve again.
    final retimed = await tools.execute(
      CompanionAgentToolCall(
        id: 'overlap-retime',
        name: 'reminder',
        input: {'operation': 'amend', 'taskId': id, 'expectedTaskRev': 2, 'selectedOffsetSeconds': -14400},
      ),
    );
    expect(retimed.isError, isFalse);
    final revised = archive.memory.store.task(id)!;
    expect(revised['task_rev'], 3);
    expect(revised['offset_seconds'], -14400);
    expect(revised['epoch_ms'], DateTime.utc(2027, 11, 7, 5, 30).millisecondsSinceEpoch);
    expect(nativeCalls.where((call) => call.method == 'resolve'), hasLength(2));
    expect(archive.memory.store.tasks(), hasLength(1));
  });

  test('a retired resolve and an unresolved old call cannot create a task', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    messenger.setMockMethodCallHandler(reminderChannel, (call) async {
      if (call.method == 'resolve') {
        entered.complete();
        await release.future;
      }
      return defaultReminder(call);
    });
    final tools = archive.bind(mode: 'light');
    const pending = CompanionAgentToolCall(
      id: 'old-pending',
      name: 'reminder',
      input: {'operation': 'create', 'text': '带伞', 'localDate': '2026-11-22', 'localTime': '08:00'},
    );
    archive.memory.store.reserveAgentTaskCall(
      turnId: archive.memoryTools.turnId,
      callId: pending.id,
      toolName: pending.name,
      input: pending.input,
    );
    final old = await tools.execute(pending);
    expect(_body(old)['code'], 'original_call_unresolved');
    expect(nativeCalls, isEmpty);
    final current = tools.execute(CompanionAgentToolCall(id: 'new', name: pending.name, input: pending.input));
    try {
      await entered.future;
      archive.current = false;
      release.complete();
      expect(_body(await current), containsPair('accepted', false));
      expect(archive.memory.store.tasks(), isEmpty);
      expect(nativeCalls.where((entry) => entry.method == 'wake'), isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      await current;
    }
  });

  for (final mode in ['light', 'full']) {
    test('$mode public lookup uses actual phone search fetch answer and original source without Host', () async {
      final requests = <http.Request>[];
      late final CompanionAgentTaskTools tools;
      tools = archive.bind(
        mode: mode,
        client: () => MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/search')) {
            final pending = await tools.execute(
              CompanionAgentToolCall(
                id: 'lookup-pending-status',
                name: 'task_status',
                input: {'taskId': archive.memory.store.tasks().single['task_id']},
              ),
            );
            expect(pending.externalWebContent, isFalse);
            expect((_body(pending)['task']! as Map)['result'], isNull);
            return _json({
              'results': [
                {'url': 'https://museum.example/notice', 'title': '青桥美术馆馆方公告', 'snippet': '搜索摘要', 'date': '2026-11-20'},
              ],
            });
          }
          if (request.url.path.endsWith('/fetch')) {
            return _json({'title': '馆方公告', 'content': '2026-11-21临时闭馆一天。'});
          }
          final saved = archive.memory.store.tasks().single;
          final fetch = archive.memory.store
              .lookupAttempts(saved['task_id']! as String)
              .singleWhere((row) => row['kind'] == 'fetch');
          return _answer({
            'status': 'done',
            'conclusion': '所问日期临时闭馆。',
            'applicable_date': '2026-11-21',
            'evidence': [
              {'fetchRequestId': fetch['request_id'], 'quote': '2026-11-21临时闭馆一天。'},
            ],
          });
        }),
      );
      final result = await tools.execute(
        const CompanionAgentToolCall(
          id: 'lookup',
          name: 'public_lookup',
          input: {'operation': 'create', 'placeName': '青桥美术馆', 'localDate': '2026-11-21', 'question': '青桥美术馆是否开放？'},
        ),
      );
      expect(result.isError, isFalse);
      final saved = archive.memory.store.lookupTask(archive.memory.store.tasks().single['task_id']! as String)!;
      expect(saved['state'], 'done');
      expect(saved['room_mode'], 'light');
      expect(saved['host_key'], isNull);
      expect(saved['host_session_id'], isNull);
      expect(saved['source_session_id'], archive.source['session_id']);
      expect(saved['lookup_deadline_ms'], _now + 120000);
      expect(requests.map((request) => request.url.path), [
        '/v1/tools/search',
        '/v1/tools/fetch',
        '/anthropic/v1/messages',
      ]);
      final attempts = archive.memory.store.lookupAttempts(saved['task_id']! as String);
      expect(attempts, hasLength(3));
      expect(attempts.every((row) => row['execution_mode'] == 'phone' && row['dispatched'] == 1), isTrue);
      expect((saved['result']! as Map)['evidence'], isNotEmpty);
      expect(result.externalWebContent, isTrue);
      final read = await tools.execute(
        CompanionAgentToolCall(id: 'lookup-result-status', name: 'task_status', input: {'taskId': saved['task_id']}),
      );
      expect(read.externalWebContent, isTrue);
      expect((_body(read)['task']! as Map)['result'], saved['result']);
      final listed = await tools.execute(
        const CompanionAgentToolCall(id: 'lookup-results-list', name: 'task_status', input: {}),
      );
      expect(listed.externalWebContent, isTrue);
      expect(((_body(listed)['tasks']! as List).single as Map)['result'], saved['result']);
      final replay = await tools.execute(
        const CompanionAgentToolCall(
          id: 'lookup',
          name: 'public_lookup',
          input: {'operation': 'create', 'placeName': '青桥美术馆', 'localDate': '2026-11-21', 'question': '青桥美术馆是否开放？'},
        ),
      );
      expect(_body(replay)['replayed'], isTrue);
      expect(replay.externalWebContent, isTrue);
      expect(requests, hasLength(3));
    });
  }

  test('the Agent cannot read or cancel an original full-room Host lookup from its phone session', () async {
    final store = archive.memory.store;
    final original = store.submitMessage(
      id: 'old-host-lookup-source',
      sessionId: 'full:original-host',
      text: '查青桥美术馆今天是否开放。',
      saidAtUtc: _now,
      offsetMinutes: 480,
      zoneId: 'Asia/Shanghai',
      offsetSeconds: 28800,
    );
    expect(archive.source['session_id'], store.lightSessionId);
    expect(original['session_id'], isNot(archive.source['session_id']));
    final old = store.createLookupFromMessage(
      messageId: original['id']! as String,
      expectedSourceRev: original['source_rev']! as int,
      itemNo: 0,
      roomMode: 'full',
      hostKey: 'original-host',
      hostSessionId: 'original-host-session',
      executorId: 'actual-phone',
      lookup: CompanionLookupSpec(
        placeName: '青桥美术馆',
        localDate: '2026-11-21',
        zoneId: 'Asia/Shanghai',
        question: '今天是否开放？',
        deadlineAtMs: _now + 120000,
      ),
    );
    store.claimLookupAttempt(
      taskId: old['task_id']! as String,
      expectedTaskRev: 1,
      requestId: 'original-host-request',
      kind: 'search',
      input: {'query': '青桥美术馆 2026-11-21 开放'},
      executorId: 'actual-phone',
      executionMode: 'host',
      instanceId: 'original-host-instance',
      provider: 'deepseek',
      model: 'configured-model',
      toolUnitPriceMicroCny: 5000,
      toolPriceAsOf: '2026-11-21',
    );
    store.observeLookupAttempt('original-host-request', dispatched: true, httpStatus: 200);
    store.markLookupUncertain('original-host-request');
    final before = store.lookupTask(old['task_id']! as String)!;
    final attemptsBefore = store.lookupAttempts(old['task_id']! as String);
    final receiptsBefore = store.taskReceipts(old['task_id']! as String);
    var phoneRequests = 0;
    final tools = archive.bind(
      client: () => MockClient((_) async {
        phoneRequests++;
        return http.Response('this old task cannot become a phone request', 503);
      }),
    );
    final listed = await tools.execute(
      const CompanionAgentToolCall(id: 'list-current', name: 'task_status', input: {}),
    );
    expect(listed.isError, isFalse);
    expect(_body(listed)['sourceSessionId'], archive.source['session_id']);
    expect(_body(listed)['tasks'], isEmpty);
    final seen = await tools.execute(
      CompanionAgentToolCall(id: 'read-old', name: 'task_status', input: {'taskId': old['task_id'], 'refresh': true}),
    );
    expect(seen.isError, isTrue);
    expect(_body(seen), containsPair('accepted', false));
    expect(_body(seen)['code'], 'task_not_in_this_room');
    final cancelled = await tools.execute(
      CompanionAgentToolCall(
        id: 'cancel-old',
        name: 'public_lookup',
        input: {'operation': 'cancel', 'taskId': old['task_id'], 'expectedTaskRev': 1},
      ),
    );
    expect(cancelled.isError, isTrue);
    expect(_body(cancelled), containsPair('accepted', false));
    expect(_body(cancelled)['code'], 'read_the_original_task_first');
    final retained = store.lookupTask(old['task_id']! as String)!;
    expect(retained, before);
    expect(retained['task_rev'], 1);
    expect(retained['cancel_requested'], 0);
    expect(retained['state'], 'unknown');
    expect(retained['wait_reason'], 'lookup_receipt_unknown');
    expect(retained['source_session_id'], 'full:original-host');
    expect(retained['room_mode'], 'full');
    expect(retained['host_key'], 'original-host');
    expect(retained['host_session_id'], 'original-host-session');
    final attempts = store.lookupAttempts(old['task_id']! as String);
    expect(attempts, attemptsBefore);
    final attempt = attempts.single;
    expect(attempt['instance_id'], 'original-host-instance');
    expect(attempt['execution_mode'], 'host');
    expect(attempt['dispatched'], 1);
    expect(attempt['finished_at_ms'], isNull);
    expect(phoneRequests, 0);
    expect(nativeCalls, isEmpty);
    final receipts = store.taskReceipts(old['task_id']! as String);
    expect(receipts, receiptsBefore);
    expect(receipts.where((row) => row['step_key'] == 'lookup.stop'), isEmpty);
  });

  test('retiring the actual pending map scope prevents handoff without declaring a physical result', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    messenger.setMockMethodCallHandler(mapChannel, (call) async {
      nativeCalls.add(call);
      if (call.method == 'capabilities') return {'executorId': 'actual-phone'};
      if (call.method == 'openScope') {
        entered.complete();
        await release.future;
        return {'scopeId': 'original-scope'};
      }
      return null;
    });
    final tools = archive.bind();
    final work = tools.execute(
      const CompanionAgentToolCall(
        id: 'map',
        name: 'map_open',
        input: {'operation': 'create', 'address': '上海市黄浦区人民大道 201 号'},
      ),
    );
    try {
      await entered.future;
      final before = archive.memory.store.mapTask(archive.memory.store.tasks().single['task_id']! as String)!;
      expect(archive.ui.acceptedTasks, isEmpty);
      tools.close();
      release.complete();
      await work;
      expect(nativeCalls.where((call) => call.method == 'handoff'), isEmpty);
      expect(nativeCalls.where((call) => call.method == 'closeScope'), hasLength(1));
      final after = archive.memory.store.mapTask(before['task_id']! as String)!;
      expect(after['task_rev'], before['task_rev']);
      expect(after['state'], isNot('done'));
      expect(archive.ui.acceptedTasks, isEmpty);
      expect(archive.ui.routes, [same(archive.ui.onSelectionRoute)]);
      expect(archive.ui.foregroundBatches, isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      await work;
    }
  });

  for (final retired in [false, true]) {
    test('a map button waits for its original handoff opportunity: retired=$retired', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      messenger.setMockMethodCallHandler(mapChannel, (call) async {
        nativeCalls.add(call);
        if (call.method == 'capabilities') return {'executorId': 'actual-phone'};
        if (call.method == 'openScope') return {'scopeId': 'original-scope'};
        if (call.method == 'handoff') {
          entered.complete();
          await release.future;
        }
        return null;
      });
      final tools = archive.bind();
      final work = tools.execute(
        const CompanionAgentToolCall(
          id: 'held-map',
          name: 'map_open',
          input: {'operation': 'create', 'address': '上海市黄浦区人民大道 201 号'},
        ),
      );
      try {
        await entered.future;
        final before = archive.memory.store.mapTask(archive.memory.store.tasks().single['task_id']! as String)!;
        expect(
          archive.memory.store.agentToolCall(turnId: archive.memoryTools.turnId, callId: 'held-map')!.state,
          'accepted',
        );
        expect(archive.ui.acceptedTasks, isEmpty);
        if (retired) {
          archive.ui.current = false;
          archive.handoff.close();
          // Coming back does not revive the captured handoff generation.
          archive.ui.current = true;
        }
        release.complete();
        final result = _body(await work);
        expect(result['accepted'], isTrue);
        final after = archive.memory.store.mapTask(before['task_id']! as String)!;
        expect(after['task_rev'], before['task_rev']);
        expect(after['cancel_requested'], 0);
        expect(after['state'], before['state'], reason: 'This channel fixture writes no physical-effect receipt');
        expect(archive.ui.acceptedTasks, hasLength(retired ? 0 : 1));
        if (!retired) expect(archive.ui.acceptedTasks.single['task_id'], before['task_id']);
        expect(nativeCalls.where((call) => call.method == 'handoff'), hasLength(1));
      } finally {
        if (!release.isCompleted) release.complete();
        await work;
      }
    });
  }

  for (final kind in ['find_draft', 'compare_drafts', 'receipts_to_sheet']) {
    test('$kind queues saved originals offline and reconnects only the original durable command', () async {
      final peer = await NotesPeer.open();
      final posts = <MemoryRow>[];
      final snapshots = <String, MemoryRow>{};
      peer.capability = {
        ...receiptsCapability,
        'sourceRead': true,
        'kinds': ['host.find_draft', 'host.compare_drafts', 'host.receipts_to_sheet'],
      };
      peer.respond = (request, body) async {
        if (request.uri.path == '$notesPath/folders') {
          return NotesPeer.json(request, {
            'v': 1,
            'hostStoreId': 'original-store',
            'folderRef': body!['path'] == '/selected/output' ? 'saved-output' : 'saved-input',
            'displayPath': body['path'],
          });
        }
        if (request.uri.path == '$notesPath/inputs') {
          return NotesPeer.json(request, {
            'v': 1,
            'hostStoreId': 'original-store',
            'sourceRef': 'saved-${body!['name']}',
            'displayName': body['name'],
            'version': 'original-v1',
            'size': 12,
            'mediaType': 'text/plain',
          });
        }
        if (request.method == 'POST' && request.uri.path == notesPath) {
          posts.add(body!);
          final snapshot = notesSnapshot(body, state: 'running');
          snapshots[body['taskId']! as String] = snapshot;
          return NotesPeer.json(request, snapshot, status: 201);
        }
        final snapshot = snapshots[request.uri.pathSegments.last];
        return snapshot == null
            ? NotesPeer.json(request, {
                'error': {'code': 'companion/task-not-found'},
              }, status: 404)
            : NotesPeer.json(request, snapshot);
      };
      try {
        final store = archive.memory.store;
        final capability = (await peer.client.readCompanionTasksCapability())!;
        final folder = await peer.client.bindCompanionNotesDirectory(capability, '/selected/input');
        final selected = <MemoryRow>[];
        for (
          var index = 0;
          index <
              (kind == 'compare_drafts'
                  ? 2
                  : kind == 'receipts_to_sheet'
                  ? 4
                  : 0);
          index++
        ) {
          selected.add(
            kind == 'compare_drafts'
                ? await peer.client.bindCompanionDraftInput(
                    capability,
                    folderRef: folder['folderRef']! as String,
                    name: 'draft-$index.txt',
                  )
                : await peer.client.bindCompanionReceiptInput(
                    capability,
                    folderRef: folder['folderRef']! as String,
                    name: 'receipt-$index.txt',
                  ),
          );
        }
        final output = kind == 'receipts_to_sheet'
            ? await peer.client.bindCompanionNotesDirectory(capability, '/selected/output')
            : null;
        final oldSource = store.submitMessage(
          id: 'earlier-selected-originals',
          sessionId: 'light:earlier-room',
          text: 'Use the originals I selected on this computer.',
          saidAtUtc: _now,
          offsetMinutes: 480,
          zoneId: 'Asia/Shanghai',
          offsetSeconds: 28800,
        );
        final args = <String, Object?>{
          if (kind == 'find_draft') ...{
            'folderRef': folder['folderRef'],
            'scope': 'currentLevel',
            'localDate': '2026-11-21',
            'timeZone': 'Asia/Shanghai',
            'dateBy': 'modified',
            'extensions': ['md', 'txt'],
          },
          if (kind == 'compare_drafts') ...{
            'a': {'sourceRef': selected[0]['sourceRef'], 'version': selected[0]['version']},
            'b': {'sourceRef': selected[1]['sourceRef'], 'version': selected[1]['version']},
            'maxHighlights': 3,
          },
          if (kind == 'receipts_to_sheet') ...{
            'inputs': [
              for (final row in selected) {'sourceRef': row['sourceRef'], 'version': row['version']},
            ],
            'outputDirRef': output!['folderRef'],
            'outputName': '本人小表.xlsx',
            'writeMode': 'createNew',
          },
        };
        final agreement = <String, Object?>{
          'args': args,
          'deadlineAtMs': null,
          'afterExit': 'continue',
          'allowQueue': true,
        };
        final previous = switch (kind) {
          'find_draft' => store.createFindDraftTaskFromMessage(
            messageId: oldSource['id']! as String,
            expectedSourceRev: 1,
            itemNo: 0,
            roomMode: 'light',
            hostKey: 'captured-host',
            directoryHostStoreId: 'original-store',
            agreement: agreement,
            directoryLabels: {'source': folder['displayPath']},
          ),
          'compare_drafts' => store.createCompareDraftTaskFromMessage(
            messageId: oldSource['id']! as String,
            expectedSourceRev: 1,
            itemNo: 0,
            roomMode: 'light',
            hostKey: 'captured-host',
            agreement: agreement,
            inputs: {'a': selected[0], 'b': selected[1]},
          ),
          _ => store.createReceiptsTaskFromMessage(
            messageId: oldSource['id']! as String,
            expectedSourceRev: 1,
            itemNo: 0,
            roomMode: 'light',
            hostKey: 'captured-host',
            agreement: agreement,
            inputs: selected,
            outputDirectory: output!,
          ),
        };
        final labels = store.hostTask(previous['task_id']! as String)!['directory_labels']! as MemoryRow;
        if (kind == 'compare_drafts') archive.ui.offlineDrafts = labels['inputs']! as MemoryRow;
        if (kind == 'receipts_to_sheet') {
          archive.ui.offlineReceipts = (
            inputs: [for (final row in labels['inputs']! as List) Map<String, Object?>.from(row as Map)],
            outputDirectory: labels['outputDirectory']! as MemoryRow,
          );
        }
        peer.calls.clear();
        final tools = archive.bind(
          mode: 'light',
          host: CompanionAgentTaskHost(
            key: 'captured-host',
            client: null,
            isCurrent: () => true,
            ensureSession: () async => throw StateError('Offline selection must not ensure a Host session'),
          ),
        );
        expect(tools.bindings.map((entry) => entry.definition.name), [
          'task_status',
          'reminder',
          'public_lookup',
          'map_open',
          'find_draft',
          'compare_drafts',
          'receipts_to_sheet',
        ]);
        final rejected = await tools.execute(
          const CompanionAgentToolCall(id: 'not-offline', name: 'notes_to_todo', input: {'operation': 'create'}),
        );
        expect(rejected.isError, isTrue);
        final accepted = await tools.execute(
          CompanionAgentToolCall(
            id: 'offline',
            name: kind,
            input: {
              'operation': 'create',
              'afterExit': 'continue',
              'allowQueue': true,
              if (kind == 'find_draft') ...{
                'localDate': '2026-11-21',
                'extensions': ['md', 'txt'],
              },
              if (kind == 'receipts_to_sheet') 'outputName': '本人小表.xlsx',
            },
          ),
        );
        expect(accepted.isError, isFalse);
        final task = store.hostTask(
          store.tasks(sourceSessionId: archive.memory.store.lightSessionId).single['task_id']! as String,
        )!;
        final id = task['task_id']! as String;
        expect(task['state'], 'queued');
        expect(task['source_message_id'], archive.source['id']);
        expect(task['room_mode'], 'light');
        expect(task['host_session_id'], isNull);
        expect(task['host_store_id'], 'original-store');
        expect(task['directory_labels'], labels);
        expect((task['agreement']! as MemoryRow)['args'], args);
        expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
        expect(store.agentToolCall(turnId: archive.memoryTools.turnId, callId: 'offline')!.state, 'accepted');
        expect(archive.ui.offlinePickers, [
          kind == 'find_draft'
              ? 'directory'
              : kind == 'compare_drafts'
              ? 'drafts'
              : 'receipts',
        ]);
        expect(peer.calls, isEmpty);
        expect(nativeCalls, isEmpty);
        // The real reconnect executor is exercised here; the Page callback and
        // its >100-task discovery remain the separate owner Widget regressions.
        final resumed = await archive.memory.hostTasks.run(
          task,
          client: peer.client,
          hostKey: 'captured-host',
          submitPending: true,
        );
        expect(resumed['state'], 'running');
        expect(posts, hasLength(1));
        expect(posts.single['origin'], {
          'sourceSessionId': archive.source['session_id'],
          'messageId': archive.source['id'],
          'itemNo': 0,
        });
        expect(posts.single['hostSessionId'], isNull);
        expect(posts.single['args'], args);
        await archive.memory.hostTasks.run(resumed, client: peer.client, hostKey: 'captured-host', submitPending: true);
        expect(posts, hasLength(1), reason: 'A possibly sent command is read, not first-delivered again');
        expect(
          peer.calls.where((call) => call.uri.path.endsWith('/inputs') || call.uri.path.endsWith('/folders')),
          isEmpty,
        );
        expect(
          peer.calls.where(
            (call) =>
                call.uri.path.contains('/session') ||
                call.uri.path.contains('/prompt') ||
                call.uri.path.contains('/auxiliary'),
          ),
          isEmpty,
        );
        expect(archive.ui.foregroundBatches, isEmpty);
        expect(archive.ui.routes.every((route) => identical(route, archive.ui.onSelectionRoute)), isTrue);
      } finally {
        await peer.close();
      }
    });
  }

  for (final kind in ['notes_to_todo', 'find_draft', 'compare_drafts', 'receipts_to_sheet']) {
    test('$kind binds real selected originals and sends only its durable command to the captured Host', () async {
      final peer = await NotesPeer.open();
      final posts = <MemoryRow>[];
      final observedJournal = <String>[];
      final snapshots = <String, MemoryRow>{};
      var sessionEnsures = 0;
      peer.capability = {
        ...receiptsCapability,
        'sourceRead': true,
        'notesForeground': true,
        'kinds': ['host.notes_to_todo', 'host.find_draft', 'host.compare_drafts', 'host.receipts_to_sheet'],
      };
      peer.respond = (request, body) async {
        if (request.uri.path == '$notesPath/folders') {
          return NotesPeer.json(request, {
            'v': 1,
            'hostStoreId': 'original-store',
            'folderRef': 'folder-${body!['path'] == '/person-selected/output' ? 'output' : 'input'}',
            'displayPath': body['path'],
          });
        }
        if (request.uri.path == '$notesPath/inputs') {
          return NotesPeer.json(request, {
            'v': 1,
            'hostStoreId': 'original-store',
            'sourceRef': 'bound-${body!['name']}',
            'displayName': body['name'],
            'version': 'exact-v1',
            'size': 12,
            'mediaType': 'text/plain',
          });
        }
        if (request.method == 'POST' && request.uri.path == notesPath) {
          posts.add(body!);
          observedJournal.add(
            archive.memory.store
                .agentToolCall(turnId: archive.memoryTools.turnId, callId: 'host-${posts.length}')!
                .state,
          );
          final snapshot = {
            ...notesSnapshot(body, state: 'waiting'),
            'hostExecutionId': 'actual-execution-${posts.length}',
            'waitReason': kind == 'notes_to_todo' ? 'foreground_required' : 'approval',
          };
          snapshots[body['taskId']! as String] = snapshot;
          return NotesPeer.json(request, snapshot, status: 201);
        }
        final snapshot = snapshots[request.uri.pathSegments.last];
        return snapshot == null
            ? NotesPeer.json(request, {
                'error': {'code': 'companion/task-not-found'},
              }, status: 404)
            : NotesPeer.json(request, snapshot);
      };
      final tools = archive.bind(
        host: CompanionAgentTaskHost(
          key: 'captured-host',
          client: peer.client,
          isCurrent: () => true,
          ensureSession: () async {
            sessionEnsures++;
            return 'actual-host-session';
          },
        ),
      );
      try {
        expect(tools.bindings.map((entry) => entry.definition.name), contains(kind));
        for (var index = 0; index < (kind == 'notes_to_todo' ? 2 : 1); index++) {
          final result = await tools.execute(
            CompanionAgentToolCall(
              id: 'host-${index + 1}',
              name: kind,
              input: {
                'operation': 'create',
                'afterExit': kind == 'notes_to_todo' ? 'pause' : 'continue',
                'allowQueue': true,
                if (kind == 'notes_to_todo' || kind == 'find_draft') 'localDate': '2026-11-21',
                if (kind == 'find_draft') 'extensions': ['md', 'txt'],
                if (kind == 'receipts_to_sheet') 'outputName': '本人小表.xlsx',
              },
            ),
          );
          expect(result.isError, isFalse);
          expect(_body(result)['receiptError'], isNull);
          expect(archive.ui.foregroundBatches, isEmpty);
        }
        expect(observedJournal.every((state) => state == 'accepted'), isTrue);
        expect(posts.map((post) => (post['origin']! as Map)['itemNo']).toSet(), hasLength(posts.length));
        expect(posts.every((post) => post['hostSessionId'] == 'actual-host-session'), isTrue);
        expect(
          posts.every((post) => (post['origin']! as Map)['sourceSessionId'] == archive.source['session_id']),
          isTrue,
        );
        expect(sessionEnsures, posts.length);
        expect(archive.ui.routes.every((route) => identical(route, archive.ui.onSelectionRoute)), isTrue);
        final args = posts.first['args']! as Map;
        if (kind == 'compare_drafts') {
          expect(args['maxHighlights'], 3);
          expect((args['a']! as Map)['sourceRef'], 'bound-a.txt');
          expect((args['b']! as Map)['sourceRef'], 'bound-b.txt');
        } else if (kind == 'receipts_to_sheet') {
          expect(args['inputs']! as List, hasLength(4));
          expect(args['outputDirRef'], 'folder-output');
          expect(args['writeMode'], 'createNew');
        } else {
          expect(args['folderRef'], 'folder-input');
          expect(args['timeZone'], 'Asia/Shanghai');
        }
        tools.close();
        if (kind == 'notes_to_todo') {
          expect(archive.ui.foregroundBatches.single, hasLength(2));
          expect(archive.ui.foregroundCurrent, [true]);
          expect(archive.ui.foregroundBatches.single.map((capture) => capture.task['host_execution_id']).toSet(), {
            'actual-execution-1',
            'actual-execution-2',
          });
          expect(archive.ui.foregroundBatches.single.every((capture) => capture.task['task_rev'] == 1), isTrue);
        } else {
          expect(archive.ui.foregroundBatches, isEmpty);
        }
        expect(peer.calls.where((call) => call.uri.path.endsWith('/foreground')), isEmpty);
      } finally {
        archive.ui.current = false;
        tools.close();
        await peer.close();
      }
    });
  }

  test('a find extension amendment keeps the original date window after the phone zone changes', () async {
    final peer = await NotesPeer.open();
    final snapshots = <String, MemoryRow>{};
    final posts = <MemoryRow>[];
    peer.capability = findCapability;
    peer.respond = (request, body) async {
      if (request.uri.path == '$notesPath/folders') {
        return NotesPeer.json(request, {
          'v': 1,
          'hostStoreId': 'original-store',
          'folderRef': 'selected-folder',
          'displayPath': body!['path'],
        });
      }
      if (request.method == 'POST' && request.uri.path == notesPath) {
        posts.add(body!);
        final snapshot = {...notesSnapshot(body, state: 'waiting'), 'waitReason': 'approval'};
        snapshots[body['taskId']! as String] = snapshot;
        return NotesPeer.json(request, snapshot, status: 201);
      }
      final snapshot = snapshots[request.uri.pathSegments.last];
      return snapshot == null
          ? NotesPeer.json(request, {
              'error': {'code': 'companion/task-not-found'},
            }, status: 404)
          : NotesPeer.json(request, snapshot);
    };
    CompanionAgentMemoryTools? amendmentMemory;
    CompanionAgentTaskTools? amendmentTools;
    try {
      final originalTools = archive.bind(
        host: CompanionAgentTaskHost(
          key: 'captured-host',
          client: peer.client,
          isCurrent: () => true,
          ensureSession: () async => 'original-host-session',
        ),
      );
      final created = await originalTools.execute(
        const CompanionAgentToolCall(
          id: 'find-original',
          name: 'find_draft',
          input: {
            'operation': 'create',
            'localDate': '2026-11-21',
            'extensions': ['md', 'txt'],
            'afterExit': 'continue',
            'allowQueue': true,
          },
        ),
      );
      expect(created.isError, isFalse);
      expect(_body(created)['receiptError'], isNull);
      final store = archive.memory.store;
      final original = store.hostTask(store.tasks().single['task_id']! as String)!;
      final id = original['task_id']! as String;
      final agreement = original['agreement']! as MemoryRow;
      final originalArgs = agreement['args']! as MemoryRow;
      expect(originalArgs['timeZone'], 'Asia/Shanghai');
      expect(posts, hasLength(1));
      originalTools.close();
      archive.memoryTools.close();
      final source = store.submitMessage(
        id: 'phone-zone-changed',
        sessionId: store.lightSessionId,
        text: 'Only change the draft extensions to txt; keep its original date window.',
        saidAtUtc: _now + 60000,
        offsetMinutes: 0,
        zoneId: 'Europe/London',
        offsetSeconds: 0,
      );
      final memoryTools = CompanionAgentMemoryTools(
        memory: archive.memory,
        source: source,
        isCurrent: () => archive.current,
        forgottenNotice: '已忘记。',
        onCommitted: ({required memory, required sourceId, required beforeRevision, required revision}) {},
      );
      amendmentMemory = memoryTools;
      final tools = CompanionAgentTaskTools(
        memoryTools: memoryTools,
        source: source,
        roomMode: 'light',
        reminders: archive.reminders,
        maps: archive.maps,
        mapHandoff: archive.handoff,
        ui: archive.ui,
        apiKey: 'actual-test-key',
        lightClientFactory: () => MockClient((_) async => http.Response('not selected', 503)),
        requestId: archive.nextId,
        host: CompanionAgentTaskHost(
          key: 'captured-host',
          client: null,
          isCurrent: () => true,
          ensureSession: () async => throw StateError('An original offline amendment must not create a Host session'),
        ),
      );
      amendmentTools = tools;
      peer.calls.clear();
      final status = await tools.execute(
        CompanionAgentToolCall(id: 'read-original', name: 'task_status', input: {'taskId': id}),
      );
      expect(status.isError, isFalse);
      expect((_body(status)['task']! as Map)['task_rev'], 1);
      final call = CompanionAgentToolCall(
        id: 'only-extensions',
        name: 'find_draft',
        input: {
          'operation': 'amend',
          'taskId': id,
          'expectedTaskRev': 1,
          'extensions': ['txt'],
        },
      );
      final amended = await tools.execute(call);
      expect(amended.isError, isFalse);
      expect(_body(amended)['receiptError'], isNull);
      final after = store.hostTask(id)!;
      final revisedAgreement = after['agreement']! as MemoryRow;
      expect(after['task_rev'], 2);
      expect(after['state'], 'queued');
      expect(after['source_zone_id'], 'Europe/London');
      expect(after['source_offset_seconds'], 0);
      expect(after['command_message_id'], source['id']);
      expect(revisedAgreement['args'], {
        ...originalArgs,
        'extensions': ['txt'],
      });
      for (final field in ['deadlineAtMs', 'afterExit', 'allowQueue']) {
        expect(revisedAgreement[field], agreement[field]);
      }
      expect(after['host_key'], original['host_key']);
      expect(after['host_store_id'], original['host_store_id']);
      expect(after['host_session_id'], original['host_session_id']);
      expect(after['directory_labels'], original['directory_labels']);
      final commands = store.hostTaskCommands(id);
      expect(commands, hasLength(2));
      expect(commands.last['possible_sent_at_ms'], isNull);
      expect((commands.last['request']! as Map)['changes'], revisedAgreement);
      expect(store.agentToolCall(turnId: memoryTools.turnId, callId: call.id)!.state, 'accepted');
      expect(_body(await tools.execute(call))['replayed'], isTrue);
      expect(store.hostTaskCommands(id), hasLength(2));
      expect(peer.calls, isEmpty);
      expect(archive.ui.directories, 1);
      expect(archive.ui.offlinePickers, isEmpty);
      expect(store.tasks(), hasLength(1));
    } finally {
      amendmentTools?.close();
      amendmentMemory?.close();
      await peer.close();
    }
  });

  test('an unrelated visit loss during actual folder selection creates no Host command', () async {
    final peer = await NotesPeer.open();
    final entered = Completer<void>();
    final release = Completer<void>();
    archive.ui.beforeDirectory = () async {
      entered.complete();
      await release.future;
    };
    final tools = archive.bind(
      host: CompanionAgentTaskHost(
        key: 'captured-host',
        client: peer.client,
        isCurrent: () => true,
        ensureSession: () async => 'actual-host-session',
      ),
    );
    final work = tools.execute(
      const CompanionAgentToolCall(
        id: 'folder',
        name: 'notes_to_todo',
        input: {'operation': 'create', 'localDate': '2026-11-21', 'afterExit': 'continue', 'allowQueue': false},
      ),
    );
    try {
      await entered.future;
      archive.ui.current = false;
      release.complete();
      expect(_body(await work), containsPair('accepted', false));
      expect(archive.memory.store.tasks(), isEmpty);
      expect(peer.calls.where((call) => call.method == 'POST'), isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      await work;
      await peer.close();
    }
  });
}
