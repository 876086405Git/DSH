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
    final connected = client!;
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
    final connected = client!;
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
      final tools = archive.bind(
        mode: mode,
        client: () => MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/search')) {
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
      final replay = await tools.execute(
        const CompanionAgentToolCall(
          id: 'lookup',
          name: 'public_lookup',
          input: {'operation': 'create', 'placeName': '青桥美术馆', 'localDate': '2026-11-21', 'question': '青桥美术馆是否开放？'},
        ),
      );
      expect(_body(replay)['replayed'], isTrue);
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
      tools.close();
      release.complete();
      await work;
      expect(nativeCalls.where((call) => call.method == 'handoff'), isEmpty);
      expect(nativeCalls.where((call) => call.method == 'closeScope'), hasLength(1));
      final after = archive.memory.store.mapTask(before['task_id']! as String)!;
      expect(after['task_rev'], before['task_rev']);
      expect(after['state'], isNot('done'));
      expect(archive.ui.routes, [same(archive.ui.onSelectionRoute)]);
      expect(archive.ui.foregroundBatches, isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      await work;
    }
  });

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
