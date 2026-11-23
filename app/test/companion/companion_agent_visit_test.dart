// Public attachment retry tests. The Agent, Ref, SQLite owner, wire decoder
// and reminder adapter are real. HTTP/native replies and the room UI port are
// explicit test boundaries; no Page, model service or native alarm is run.
import 'dart:async';
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
import 'package:dsh_app/companion/companion_notice_channel.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_public_lookup.dart';
import 'package:dsh_app/companion/companion_signal_consent.dart';
import 'package:dsh_app/companion/companion_signals.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/companion/companion_widget.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/notify/chat_alerts.dart';
import 'package:dsh_app/pets/pet_signals.dart';
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

import 'companion_notice_triage_test.dart' show FakeCompanionNotices;
import '../../../packages/dsh_client/test/support/companion_signal_host.dart';

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

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'the actual asynchronous boundary did not settle');
}

class _Loopback extends HttpOverrides {}

// The existing signal-room fixture's controlled task result, carried by a
// real ready mux and HostAlertTracker; no private Agent preparation is called.
class _TerminalSource extends DshAlertSource {
  _TerminalSource(super.client);
  final listed = Completer<void>();
  int seq = 10;
  String reason = 'completed';
  @override
  Future<List<SessionSummary>> listSessions() async {
    if (!listed.isCompleted) listed.complete();
    return [
      SessionSummary.fromJson({
        'sessionId': 's-photos',
        'running': false,
        'blank': false,
        'agentAvailable': true,
        'updatedAt': 1794090000000,
        'projections': {'title': '整理照片'},
      }),
    ];
  }

  @override
  Future<TurnOutcome?> lastTurn(String sessionId) async => outcomeFromEvents([
    TurnEndedEvent(seq, DateTime.utc(2026, 11, 7), const {}, turn: 2, reason: TurnEndReason(reason)),
  ], title: '整理照片');
}

class _TerminalSignals {
  _TerminalSignals(this.host, this.connection, this.source);
  final CompanionSignalTestHost host;
  final HostConnection connection;
  final _TerminalSource source;
  final deliveries = <CompanionAlertDelivery>[];
  late final HostAlertTracker tracker;
  bool _closed = false;

  static Future<_TerminalSignals> open() => HttpOverrides.runWithHttpOverrides(() async {
    final host = await CompanionSignalTestHost.start();
    final client = await host.connect().timeout(const Duration(seconds: 5));
    final connection = HostConnection(client: client, isLocal: true);
    final source = _TerminalSource(client);
    final signals = _TerminalSignals(host, connection, source);
    addTearDown(signals.close);
    signals.tracker = HostAlertTracker(
      host: HostRef.local,
      source: source,
      companionConnection: connection,
      isCompanionAttached: () => true,
      onCompanionSignal: signals.deliveries.add,
      onAlert: (_) {},
      onWithdraw: (_, _, _) {},
      onSessionGone: (_, _) {},
      announceDelay: Duration.zero,
      reconcileDelay: const Duration(milliseconds: 1),
    )..start();
    await source.listed.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    return signals;
  }, _Loopback());

  Future<void> emit(ProviderContainer container, {String reason = 'completed'}) async {
    source
      ..reason = reason
      ..seq += 1;
    final before = deliveries.length;
    await host.proof(connection.client, session: 's-photos', running: true).timeout(const Duration(seconds: 5));
    await host.proof(connection.client, session: 's-photos', running: false).timeout(const Duration(seconds: 5));
    await _until(() => deliveries.length > before);
    expect(deliveries, hasLength(before + 1));
    container.read(petEventBusProvider).companionSignal(deliveries.last);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await tracker.dispose();
    await host.close();
  }
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
  final controlChanges = <bool>[];
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
  void controlChanged({required bool own}) => controlChanges.add(own);
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

class _FollowupUi extends _RoomUi {
  bool visible = false;
  Completer<CompanionInitiativeDisplay> presented = Completer();
  final displays = <CompanionInitiativeDisplay>[];
  final lines = <String>[];

  @override
  CompanionInitiativeView get initiativeView => CompanionInitiativeView(
    visible: visible,
    resumed: true,
    blocked: false,
    enabled: true,
    accessible: false,
    contextKey: 'followup-affinity-port',
  );

  @override
  bool canPresent(CompanionInitiativeTicket ticket) => mounted && visible && ticket.kind == CompanionPromptKind.signal;

  @override
  bool presentFollowup(CompanionInitiativeDisplay display, String line) {
    if (!mounted || !visible) return false;
    displays.add(display);
    lines.add(line);
    presented.complete(display);
    return true;
  }
}

class _AmbientUi extends _RoomUi implements CompanionAgentAmbientUi {
  final presented = <({String id, String text, String emotion, bool speak})>[];
  Completer<void>? entered;
  Completer<bool>? acknowledgement;
  @override
  bool get presentationAvailable => mounted;
  @override
  Future<bool> presentLine({required String id, required String text, required String emotion, required bool speak}) {
    presented.add((id: id, text: text, emotion: emotion, speak: speak));
    if (entered case final signal?) {
      if (!signal.isCompleted) signal.complete();
    }
    return acknowledgement?.future ?? Future.value(true);
  }

  @override
  void stopSpeech() {}
}

class _NotificationUi extends _RoomUi implements CompanionAgentNotificationUi {
  _NotificationUi(this.agent, this.enabled);
  final CompanionAgent agent;
  final bool Function() enabled;
  CompanionAgentResident? resident;
  final delivered = <({String id, String text})>[];
  final entered = Completer<void>();
  final acknowledgement = Completer<bool>();
  bool get available => mounted && resident?.active == true;

  @override
  CompanionInitiativeView get initiativeView => CompanionInitiativeView(
    visible: false,
    resumed: false,
    // Match the production notification port: only this resident's exact
    // in-flight signal preparation may pass its own busy observation.
    blocked: agent.running && resident?.preparingSignalId == null,
    enabled: available && enabled(),
    accessible: false,
    notificationAvailable: available,
    contextKey: 'resident-task-port',
  );

  @override
  bool canPresent(CompanionInitiativeTicket ticket) {
    final preparing = resident?.preparingSignalId;
    return available &&
        enabled() &&
        ticket.kind == CompanionPromptKind.signal &&
        (!agent.running || (preparing != null && ticket.signalId == preparing));
  }

  @override
  Future<bool> deliverFollowup({required String id, required String text}) {
    delivered.add((id: id, text: text));
    if (!entered.isCompleted) entered.complete();
    return acknowledgement.future;
  }
}

class _Visit {
  _Visit(this.root, this.database, this.memory, this.replies, {_RoomUi? roomUi}) : ui = roomUi ?? _RoomUi();
  final Directory root;
  final Database database;
  final CompanionMemoryOwner memory;
  final List<http.Response> replies;
  final requests = <Map<String, Object?>>[];
  final native = <MethodCall>[];
  final _RoomUi ui;
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
    Future<void> Function(Map<String, Object?> body)? beforeReply,
    _RoomUi? roomUi,
    CompanionNotices? notices,
    CompanionInitiativeClock Function()? clock,
    CompanionMemoryTransport Function()? memoryTransport,
    HostConnection? connection,
  }) async {
    int now() => clock?.call().wallMs ?? _now;
    final root = await Directory.systemTemp.createTemp('agent-public-visit-');
    final database = sqlite3.openInMemory();
    final memory = CompanionMemoryOwner(
      CompanionMemoryStore(database, nowMilliseconds: now),
      CompanionLocal.at(root, nowMilliseconds: now),
      nowMilliseconds: now,
    );
    final visit = _Visit(root, database, memory, replies, roomUi: roomUi);
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
        memoryTransport: memoryTransport ?? (() => background),
        host: () => null,
        apiKey: () => 'controlled-test-key',
        client: () => MockClient((request) async {
          if (auxiliary?.call(request) case final response?) return response;
          visit.requests.add(Map<String, Object?>.from(jsonDecode(request.body) as Map));
          final index = visit.requests.length - 1;
          await beforeReply?.call(visit.requests[index]);
          return index < replies.length ? replies[index] : http.Response('Unexpected extra model request', 503);
        }),
      );
      ref.onDispose(agent.dispose);
      return agent;
    });
    visit._container = ProviderContainer(
      overrides: [
        if (notices != null) ...[
          operatingSystemProvider.overrideWithValue('android'),
          companionNoticesProvider.overrideWithValue(notices),
        ],
        activeHostProvider.overrideWith(_Host.new),
        activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(connection)),
        companionMemoryOwnerProvider(root.absolute.path).overrideWith((ref) => memory),
        companionInitiativeClockProvider.overrideWithValue(
          clock ?? (() => CompanionInitiativeClock(wallMs: _now, monoMs: 0, offsetMinutes: 480)),
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

// Only the Android inbox is faked. Source timestamps, person and package
// follow the channel contract while classification and delivery use the visit.
class _NoticeInbox extends FakeCompanionNotices {
  final firstJudged = Completer<void>();
  final firstSaid = Completer<void>();
  @override
  Future<CompanionNoticeBatch?> takeBatch(String pkg, List<String> keys, int expected) async {
    final batch = await super.takeBatch(pkg, keys, expected);
    if (batch == null) return null;
    return CompanionNoticeBatch(
      pkg: pkg,
      appName: '聊天',
      level: batch.level,
      epoch: batch.epoch,
      consentEpoch: batch.consentEpoch,
      items: [
        for (final item in batch.items)
          (
            key: item.key,
            segments: [
              for (final segment in item.segments) (text: segment.text, atMs: segment.atMs, personId: 'a' * 64),
            ],
          ),
      ],
    );
  }

  @override
  Future<bool> record(int epoch, {int judged = 0, int said = 0}) async {
    final recorded = await super.record(epoch, judged: judged, said: said);
    if (recorded && judged > 0 && !firstJudged.isCompleted) firstJudged.complete();
    if (recorded && said > 0 && !firstSaid.isCompleted) firstSaid.complete();
    return recorded;
  }
}

const _offer = '聊天里小石问起周末安排，要我帮你想个回复吗？';
http.Response _noticeOutput({bool remember = false}) => _message(
  words: jsonEncode([
    {
      'id': 0,
      'segment': 0,
      'action': remember ? 'remember' : 'say',
      'person': '小石',
      'text': remember ? '周五有包裹要领。' : _offer,
      if (remember) ...{'topic': 'delivery', 'sensitive': false} else 'offerReply': true,
    },
  ]),
);

Future<_Visit> _shownOffer(List<http.Response> replies) async {
  SharedPreferences.setMockInitialValues({'companion_mode': 'light', 'companion_initiative_enabled': true});
  final inbox = _NoticeInbox();
  addTearDown(inbox.events.close);
  final room = _FollowupUi();
  var advance = 0;
  inbox.post('a', 'b' * 64, DateTime.fromMillisecondsSinceEpoch(_now - 30000), '小石 · 周末你回家吗');
  final visit = await _Visit.open(
    [_noticeOutput(), ...replies],
    notices: inbox,
    roomUi: room,
    clock: () => CompanionInitiativeClock(wallMs: _now + advance, monoMs: advance, offsetMinutes: 480),
  );
  await inbox.firstJudged.future.timeout(const Duration(seconds: 5));
  await Future<void>.delayed(Duration.zero);
  room.visible = true;
  visit.attachment.observe(room.initiativeView);
  advance += 46000;
  visit.attachment.observe(room.initiativeView);
  await inbox.firstSaid.future.timeout(const Duration(seconds: 5));
  expect(room.lines, [_offer]);
  return visit;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({'companion_mode': 'light', 'companion_initiative_enabled': false}),
  );

  test('notice visit keeps an unrelated user task ordinary after an actually shown offer', () async {
    final visit = await _shownOffer([_message(words: '可以。')]);
    visit.attachment.acted();
    await visit.attachment.submit('明天提醒我买水果。');
    expect(visit.attachment.error, isNull);
    expect(_context(visit.requests.last), isNot(contains('noticeReply')));
    expect((visit.requests.last['tools'] as List).cast<Map>().map((tool) => tool['name']), contains('reminder'));
    expect(visit.memory.store.messages().where((row) => row['role'] == 'assistant').single['text'], '可以。');
  });

  test('notice visit retries draft without tools and requires its full frame before phone approval', () async {
    const phone = MethodChannel('dsh/phone');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final approvals = <MethodCall>[];
    messenger.setMockMethodCallHandler(phone, (call) async {
      if (call.method == 'companionPhoneTools') {
        return [
          {
            'name': 'status',
            'description': 'status',
            'inputSchema': {'type': 'object'},
          },
        ];
      }
      if (call.method == 'companionPhoneBegin') {
        approvals.add(call);
        return {'decision': 'denied'};
      }
      if (call.method == 'companionPhoneEnd') return null;
      throw StateError('Unexpected phone action');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(phone, null));
    const draft = '我还在确认时间，晚些告诉你。';
    final visit = await _shownOffer([
      http.Response('temporary failure', 503),
      _message(words: draft),
      _message(calls: [('phone-first', 'phone_status', {})]),
      _message(words: '尚未操作手机。'),
    ]);
    final room = visit.attachment;
    room.acted();
    await room.submit('帮我回复');
    expect(room.error, isNotNull);
    expect(room.pendingReplyRanges, isEmpty);
    room.acted();
    await room.submit('帮我回复');
    expect(room.error, isNull);
    for (final request in visit.requests.skip(1).take(2)) {
      expect((_context(request)['noticeReply'] as Map)['phase'], 'draft');
      expect(request['tools'] ?? const [], isEmpty);
    }
    expect(approvals, isEmpty);
    expect(room.text, draft);
    final ranges = room.pendingReplyRanges;
    expect(ranges.keys.single, 'notice-draft:${room.replyId}');
    expect(ranges.values.single, (start: 0, end: draft.length));
    room.presentedReply(room.replyId!, draft.substring(0, 2), sourceIds: ranges.keys.toSet());
    expect(room.pendingReplyRanges, ranges);
    room.presentedReply(room.replyId!, draft, sourceIds: ranges.keys.toSet());
    expect(room.pendingReplyRanges, isEmpty);
    room.acted();
    await room.submit('确认发送');
    expect(room.error, isNull);
    final request = visit.requests[3];
    expect((_context(request)['noticeReply'] as Map)['shown_draft'], draft);
    expect((_context(request)['noticeReply'] as Map)['phase'], 'confirmed');
    expect((request['tools'] as List).cast<Map>().map((tool) => tool['name']), ['phone_status']);
    expect((approvals.single.arguments as Map)['sourceText'], '确认发送');
    final messages = visit.memory.store.messages();
    expect(messages.where((row) => row['role'] == 'assistant'), isEmpty);
    expect(messages.where((row) => row['role'] == 'user').map((row) => row['text']), containsAll(['帮我回复', '确认发送']));
  });

  test('notice visit rejects delayed resident draft delivery after its app is switched off', () async {
    const draft = '我会先看看行程，再告诉你。';
    final visit = await _shownOffer([_message(words: draft)]);
    final resident = visit.agent.retainAlwaysOn(
      root: Future.value(visit.root),
      character: const CompanionCharacter(name: '伙伴'),
      moves: const CompanionMoves(),
      sourceKey: null,
      ui: _RoomUi(),
      mapHandoff: CompanionMapHandoff(visit.container.read(companionMapsProvider)),
    );
    addTearDown(resident.close);
    await resident.submit('帮我回复');
    expect(resident.ownsCurrentRun, isTrue);
    expect((_context(visit.requests.last)['noticeReply'] as Map)['phase'], 'draft');
    expect(visit.attachment.error, isNull);
    expect(visit.attachment.running, isFalse);
    final id = visit.attachment.replyId!;
    expect(visit.attachment.text, draft);
    final inbox = visit.container.read(companionNoticesProvider);
    final status = await inbox.setLevel('a', CompanionNoticeLevel.off);
    expect(status.readable, isTrue);
    var delivered = false;
    final shown = await resident.deliverReply(id, draft, (_) async {
      delivered = true;
      return true;
    });
    expect(shown, isFalse);
    expect(delivered, isFalse);
  });

  test('notice visit remembers a 48-hour event and discards a model result after lock', () async {
    final inbox = _NoticeInbox();
    addTearDown(inbox.events.close);
    final held = Completer<void>();
    final release = Completer<void>();
    final returned = Completer<void>();
    var requests = 0;
    final sourceTime = _now - const Duration(days: 2).inMilliseconds;
    inbox.post('a', 'b' * 64, DateTime.fromMillisecondsSinceEpoch(sourceTime), '小石 · 请留意周五送到门房的包裹');
    final visit = await _Visit.open(
      [_noticeOutput(remember: true), _noticeOutput()],
      notices: inbox,
      beforeReply: (_) async {
        if (++requests == 2) {
          held.complete();
          await release.future;
          returned.complete();
        }
      },
    );
    await inbox.firstJudged.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    final row = visit.memory.store.noticeMemories().single;
    expect(row['text'], '周五有包裹要领。');
    inbox.post('a', 'c' * 64, DateTime.fromMillisecondsSinceEpoch(_now - 30000), '小石 · 周末安排定了吗');
    await held.future.timeout(const Duration(seconds: 5));
    inbox.lock();
    release.complete();
    await returned.future;
    await Future<void>.delayed(Duration.zero);
    inbox.unlocked = true;
    inbox.events.add(++inbox.epoch);
    await Future<void>.delayed(Duration.zero);
    expect(inbox.judged, 1);
    expect(inbox.said, 0);
    expect(inbox.inbox, isEmpty);
    expect(requests, 2);
    expect(visit.memory.store.noticeMemories(), hasLength(1));
  });

  test('public attachment retries a no-tool failure with the same source clock and open turn', () async {
    const savedCustom = '我是已保存的星桥旅伴。';
    const savedCallMe = '阿榛';
    // Seed storage without reading or warming the lazy persona provider.
    SharedPreferences.setMockInitialValues({
      'companion_mode': 'light',
      'companion_initiative_enabled': false,
      'companion_persona_v1': jsonEncode({'custom': savedCustom, 'callMe': savedCallMe}),
    });
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
      // Real wire bodies: cold first request, explicit retry and continuation.
      for (final request in visit.requests) {
        expect(_context(request)['window'], 'room');
        final system = jsonEncode(request['system']);
        expect(system, contains(savedCustom));
        expect(system, contains(savedCallMe));
      }
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
    final replies = [
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
    ];
    final visit = await _Visit.open(replies);
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
      final recalledResult = <Map>[
        for (final message in (visit.requests[1]['messages']! as List).cast<Map>())
          if (message['role'] == 'user' && message['content'] is List)
            for (final row in (message['content']! as List).cast<Map>())
              if (row['type'] == 'tool_result') row,
      ].singleWhere((row) => row['tool_use_id'] == 'private-recall');
      expect((jsonDecode(recalledResult['content']! as String) as Map).containsKey('control'), isFalse);
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

      // An unrelated source/card stays independent. The deleted source below
      // is created by a real attachment submission and paid HTTP tool loop.
      final store = visit.memory.store;
      final originalSource = visit.userSource;
      const keptText = '我收藏明信片。';
      final keptSource = store.submitMessage(
        id: 'raw-kept-postcards',
        sessionId: originalSource['session_id']! as String,
        characterId: originalSource['character_id'] as String?,
        text: keptText,
        saidAtUtc: _now,
        offsetMinutes: originalSource['offset_minutes']! as int,
      );
      final keptTurn =
          store.beginAgentTurn(
                messageId: keptSource['id']! as String,
                expectedSourceRev: keptSource['source_rev']! as int,
                shownCardRevisions: const {},
              )['id']!
              as String;
      final kept = store.applyAgentMemoryTool(
        turnId: keptTurn,
        callId: 'raw-keep',
        toolName: 'remember',
        input: {
          'text': keptText,
          'keywords': ['明信片'],
        },
      );
      expect(kept.applied, isTrue);
      store.closeAgentTurn(keptTurn);
      final keptCard = store.cards().singleWhere((card) => card['id'] == kept.targetId);
      visit.memory.changed();

      const rawText = '我住海棠路二十号。';
      replies.addAll([
        _message(
          calls: [
            (
              'raw-remember',
              'remember',
              {
                'text': rawText,
                'keywords': ['海棠路'],
              },
            ),
          ],
        ),
        _message(words: '这条住址已记下。'),
      ]);
      await visit.attachment.submit(rawText);
      expect(visit.attachment.error, isNull);
      expect(visit.requests, hasLength(6));
      final rawSource = store.messages().singleWhere((row) => row['id'] == visit.agent.sourceId);
      expect(rawSource['text'], rawText);
      expect(rawSource['session_id'], originalSource['session_id']);
      expect(rawSource['character_id'], originalSource['character_id']);
      final rawCard = store.cards().singleWhere((card) => card['text'] == rawText);
      expect((rawCard['evidence'] as List).single, containsPair('message_id', rawSource['id']));
      expect(jsonEncode(visit.requests[4]), contains(rawText));
      final paid = {for (final row in store.requests()) row['id']! as String: row};
      expect(paid, hasLength(6));
      for (final row in paid.values) {
        expect(row['sent_at_ms'], isNotNull);
        expect(row['state'], 'finished');
        expect(row['terminal'], 'complete');
        expect(row['input_uncached'], 12);
        expect(row['output_tokens'], 8);
        expect(row['raw_usage'], containsPair('http_status', 200));
      }

      replies.addAll([
        _message(
          calls: [
            ('raw-forget', 'forget', {'card': rawCard['id'], 'deleteChat': true}),
          ],
        ),
        _message(words: '这条住址和原话都已删除。'),
      ]);
      await visit.attachment.submit('忘掉海棠路这条住址，连原话也删。');
      expect(visit.attachment.error, isNull);
      expect(visit.requests, hasLength(8));
      final beforeDelete = jsonEncode(visit.requests[6]);
      expect(beforeDelete, contains(rawText));
      expect(beforeDelete, contains(rawCard['id']! as String));
      final forgetDefinition = (visit.requests[6]['tools']! as List).cast<Map>().singleWhere(
        (tool) => tool['name'] == 'forget',
      );
      final properties = (forgetDefinition['input_schema']! as Map)['properties']! as Map;
      expect(properties['deleteChat'], containsPair('type', 'boolean'));
      final quietDefinition = (visit.requests[6]['tools']! as List).cast<Map>().singleWhere(
        (tool) => tool['name'] == 'quiet',
      );
      final quietProperties = (quietDefinition['input_schema']! as Map)['properties']! as Map;
      expect((quietProperties['mode']! as Map)['enum'], unorderedEquals(['less', 'never', 'normal']));
      expect(quietProperties['topic'], containsPair('type', 'string'));
      final quietSchema = quietDefinition['input_schema']! as Map;
      expect(quietSchema['required'], ['mode']);
      expect(quietSchema['oneOf'], [
        {
          'required': ['card'],
          'not': {
            'required': ['topic'],
          },
        },
        {
          'required': ['topic'],
          'not': {
            'required': ['card'],
          },
          'properties': {
            'mode': {
              'enum': ['normal'],
            },
          },
        },
      ]);
      expect(jsonEncode(visit.requests[7]), isNot(contains(rawText)));
      final rawResults = <Map>[
        for (final message in (visit.requests[7]['messages']! as List).cast<Map>())
          if (message['role'] == 'user' && message['content'] is List)
            for (final row in (message['content']! as List).cast<Map>())
              if (row['type'] == 'tool_result') row,
      ];
      expect(rawResults.single['tool_use_id'], 'raw-forget');
      expect(jsonDecode(rawResults.single['content']! as String), containsPair('applied', true));
      expect(store.messages().any((row) => row['id'] == rawSource['id']), isFalse);
      expect(store.cards().any((card) => card['id'] == rawCard['id']), isFalse);
      final retainedSource = store.messages().singleWhere((row) => row['id'] == keptSource['id']);
      expect(retainedSource['text'], keptText);
      expect(retainedSource['source_rev'], keptSource['source_rev']);
      expect(store.cards().singleWhere((card) => card['id'] == kept.targetId), keptCard);

      // Deleting raw text does not refund or erase the actual prior requests.
      // Match IDs: this fixture's equal timestamps do not define HTTP order.
      final after = {for (final row in store.requests()) row['id']! as String: row};
      expect(after, hasLength(8));
      for (final entry in paid.entries) {
        expect(after[entry.key], entry.value);
      }
      final newRequests = after.entries
          .where((entry) => !paid.containsKey(entry.key))
          .map((entry) => entry.value)
          .toList();
      expect(newRequests, hasLength(2));
      for (final row in newRequests) {
        expect(row['origin'], 'local');
        expect(row['category'], 'chat');
        expect(row['sent_at_ms'], isNotNull);
        expect(row['state'], 'finished');
        expect(row['terminal'], 'complete');
        expect(row['input_uncached'], 12);
        expect(row['input_cache_read'], 0);
        expect(row['input_cache_write'], 0);
        expect(row['output_tokens'], 8);
        expect(row['raw_usage'], containsPair('http_status', 200));
        expect(row['raw_usage'], containsPair('complete', true));
      }

      // A real user invitation reaches both fixed and ordinary layers, but
      // the next ordinary user turn does not inherit that permission. Keep
      // all eight original HTTP/forget/usage observations above intact.
      visit.attachment.updateCharacter(
        const CompanionCharacter(name: '伙伴'), const CompanionMoves(),
        sourceKey: 'builtin:companion/whale-girl',
      );
      expect(await visit.attachment.openMemory(), same(visit.memory));
      final invitationRole = visit.attachment.characterId!;
      final invitationSource = store.submitMessage(
        id: 'wire-fixed-invitation-source',
        sessionId: originalSource['session_id']! as String,
        characterId: invitationRole,
        text: '我们看过玉兰，散步时更自在。',
        saidAtUtc: _now,
        offsetMinutes: originalSource['offset_minutes']! as int,
      );
      final invitationSetup = store.beginAgentTurn(
        messageId: invitationSource['id']! as String,
        expectedSourceRev: invitationSource['source_rev']! as int,
        shownCardRevisions: {kept.targetId!: keptCard['row_rev']! as int},
      )['id']! as String;
      expect(store.applyAgentMemoryTool(
        turnId: invitationSetup, callId: 'wire-quiet-postcards', toolName: 'quiet',
        input: {'card': kept.targetId, 'mode': 'never'},
      ).applied, isTrue);
      final invitationStory = store.applyAgentMemoryTool(
        turnId: invitationSetup, callId: 'wire-magnolia-story', toolName: 'remember',
        input: {'collection': 'our_story', 'text': '我们看过玉兰。', 'keywords': ['玉兰']},
      );
      expect(invitationStory.applied, isTrue);
      expect(store.applyAgentMemoryTool(
        turnId: invitationSetup, callId: 'wire-quiet-magnolia', toolName: 'quiet',
        input: {'card': invitationStory.targetId, 'mode': 'never'},
      ).applied, isTrue);
      const impressionText = '聊过玉兰之后，散步时彼此更自在。';
      final invitationImpression = store.applyAgentMemoryTool(
        turnId: invitationSetup, callId: 'wire-magnolia-impression', toolName: 'impression',
        input: {'text': impressionText, 'keywords': ['散步']},
      );
      expect(invitationImpression.applied, isTrue);
      store.closeAgentTurn(invitationSetup);
      final storyRow = store.cards().singleWhere((row) => row['id'] == invitationStory.targetId);
      final impressionRow = store.cards().singleWhere((row) => row['id'] == invitationImpression.targetId);
      expect(impressionRow['topic_id'], storyRow['topic_id']);
      expect(impressionRow['topic_mode'], 'never');
      final invitationControls = store.topicControls();
      visit.memory.changed();
      replies.addAll([
        _message(calls: [('wire-fixed-related', 'related', {'card': invitationImpression.targetId})]),
        _message(words: '想起玉兰时，散步也很轻松。'),
      ]);
      await visit.attachment.submit('聊聊玉兰');
      expect(visit.attachment.error, isNull);
      expect(visit.requests, hasLength(10));
      for (final body in visit.requests.skip(8).take(2)) {
        final blocks = <Map>[
          for (final message in (body['messages']! as List).cast<Map>())
            if (message['role'] == 'user' && message['content'] is List)
              for (final block in (message['content']! as List).cast<Map>())
                if (block['type'] == 'text' && (block['text']! as String).startsWith('{"type":"companion_memory"'))
                  jsonDecode(block['text']! as String) as Map,
        ];
        final items = (blocks.single['items']! as List).cast<Map>();
        expect(items.map((row) => row['id']), containsAll([invitationStory.targetId, invitationImpression.targetId]));
        expect(items.singleWhere((row) => row['id'] == invitationImpression.targetId)['text'], impressionText);
      }
      final invitedToolResult = <Map>[
        for (final message in (visit.requests[9]['messages']! as List).cast<Map>())
          if (message['role'] == 'user' && message['content'] is List)
            for (final block in (message['content']! as List).cast<Map>())
              if (block['type'] == 'tool_result') block,
      ].singleWhere((row) => row['tool_use_id'] == 'wire-fixed-related');
      expect(jsonDecode(invitedToolResult['content']! as String), containsPair('applied', true));

      replies.addAll([
        _message(calls: [('wire-explicit-recall', 'recall', {'query': '聊聊玉兰'})]),
        _message(words: '今天也可以慢慢聊。'),
      ]);
      await visit.attachment.submit('今天随便说几句。');
      expect(visit.attachment.error, isNull);
      expect(visit.requests, hasLength(12));
      for (final body in visit.requests.skip(10)) {
        final fixedBlocks = <Map>[
          for (final message in (body['messages']! as List).cast<Map>())
            if (message['role'] == 'user' && message['content'] is List)
              for (final block in (message['content']! as List).cast<Map>())
                if (block['type'] == 'text' && (block['text']! as String).startsWith('{"type":"companion_memory"'))
                  jsonDecode(block['text']! as String) as Map,
        ];
        expect(fixedBlocks, isEmpty);
      }
      final explicitRecallResult = <Map>[
        for (final message in (visit.requests[11]['messages']! as List).cast<Map>())
          if (message['role'] == 'user' && message['content'] is List)
            for (final block in (message['content']! as List).cast<Map>())
              if (block['type'] == 'tool_result') block,
      ].singleWhere((row) => row['tool_use_id'] == 'wire-explicit-recall');
      final recallPayload = jsonDecode(explicitRecallResult['content']! as String) as Map;
      expect(recallPayload['applied'], isTrue);
      expect(((recallPayload['selection']! as Map)['items']! as List).cast<Map>().map((row) => row['id']), [invitationStory.targetId]);
      expect(store.cards().singleWhere((row) => row['id'] == invitationImpression.targetId), impressionRow);
      expect(store.cards().singleWhere((row) => row['id'] == invitationStory.targetId), storyRow);
      expect(store.topicControls(), invitationControls);
      final afterInvitations = {for (final row in store.requests()) row['id']! as String: row};
      expect(afterInvitations, hasLength(12));
      for (final entry in after.entries) {
        expect(afterInvitations[entry.key], entry.value);
      }
      final invitationRequests = afterInvitations.entries.where((entry) => !after.containsKey(entry.key)).map((entry) => entry.value).toList();
      expect(invitationRequests, hasLength(4));
      for (final row in invitationRequests) {
        expect(row['sent_at_ms'], isNotNull);
        expect(row['terminal'], 'complete');
        expect(row['state'], 'finished');
        expect(row['input_uncached'], 12);
        expect(row['output_tokens'], 8);
        expect(row['raw_usage'], containsPair('http_status', 200));
      }
    } finally {
      await visit.close();
    }
  });

  test(
    'public followup affinity receipts survive owner rebuild and deduplicate the actual shown opportunity',
    () async {
      SharedPreferences.setMockInitialValues({'companion_mode': 'light', 'companion_initiative_enabled': true});
      var wall = _now, mono = 0;
      var configured = false;
      final room = _FollowupUi();
      final requests = <Map>[];
      final transport = CompanionLightMemoryTransport(
        apiKey: () => configured ? 'controlled-test-key' : '',
        client: () => MockClient((request) async {
          requests.add(jsonDecode(request.body) as Map);
          return _message(words: jsonEncode({'action': 'line', 'text': '后来怎么样了？'}));
        }),
      );
      final visit = await _Visit.open(
        const [],
        roomUi: room,
        clock: () => CompanionInitiativeClock(wallMs: wall, monoMs: mono),
        memoryTransport: () => transport,
      );
      try {
        final store = visit.memory.store;
        final opportunities = <String>[];
        final presentations = <String>[];
        CompanionInitiative? previousOwner;
        String? firstRole;
        for (var round = 0; round < 2; round++) {
          if (round != 0) {
            configured = false;
            room.visible = false;
            visit.attachment.detach();
            // Rebuild the real initiative owner from the same durable ledger.
            // Its UI counter restarts; the actual shown receipts must survive.
            visit.container.invalidate(companionInitiativeProvider);
            wall += const Duration(days: 2).inMilliseconds;
            mono += const Duration(days: 2).inMilliseconds;
            room
              ..mounted = true
              ..presented = Completer();
            visit._attachment = visit.agent.attach(
              root: Future.value(visit.root),
              character: const CompanionCharacter(name: '伙伴'),
              moves: const CompanionMoves(),
              ui: room,
              mapHandoff: CompanionMapHandoff(visit.container.read(companionMapsProvider)),
            );
            await visit.attachment.openMemory();
          }
          visit.attachment.updateCharacter(
            const CompanionCharacter(name: '伙伴'),
            const CompanionMoves(),
            sourceKey: 'local:followup-affinity-test',
          );
          final owner = visit.container.read(companionInitiativeProvider);
          if (previousOwner != null) expect(identical(owner, previousOwner), isFalse);
          previousOwner = owner;
          final role = visit.attachment.characterId!;
          firstRole ??= role;
          expect(role, firstRole);

          final source = store.submitMessage(
            id: 'followup-source-$round',
            sessionId: store.lightSessionId,
            text: round == 0 ? '我打算修琴，之后再问我。' : '我打算修画，之后再问我。',
            saidAtUtc: wall,
            offsetMinutes: 0,
            characterId: role,
          );
          final turn =
              store.beginAgentTurn(
                    messageId: source['id']! as String,
                    expectedSourceRev: source['source_rev']! as int,
                    shownCardRevisions: const {},
                  )['id']!
                  as String;
          final remembered = store.applyAgentMemoryTool(
            turnId: turn,
            callId: 'card-$round',
            toolName: 'remember',
            input: {'text': round == 0 ? '打算修琴' : '打算修画'},
          );
          expect(remembered.applied, isTrue);
          final later = store.applyAgentMemoryTool(
            turnId: turn,
            callId: 'later-$round',
            toolName: 'ask_later',
            input: {'card': remembered.targetId, 'whenMs': wall},
          );
          expect(later.applied, isTrue);
          final opportunity = later.targetId!;
          opportunities.add(opportunity);
          store.closeAgentTurn(turn);
          visit.memory.changed();
          // The worker claims its run before it asks for the (async) route;
          // with no key configured that run ends without a request.
          await pumpEventQueue();
          expect(visit.memory.working, isFalse);

          configured = true;
          room.visible = true;
          visit.attachment.observe(room.initiativeView);
          // Advance both injected clocks, then give the real owner a fresh
          // observation using the existing clock seam, without a wall-time sleep.
          wall += 46000;
          mono += 46000;
          visit.attachment.observe(room.initiativeView);
          await room.presented.future.timeout(const Duration(seconds: 5));
          // Visit deliberately records only after synchronous shown settlement.
          await Future<void>.microtask(() {});
          final shown = store.followups().singleWhere((row) => row['id'] == opportunity);
          expect(shown['state'], 'asked');
          expect(shown['presented_at_ms'], wall);
          final spends = visit.database.select('SELECT state FROM memory_initiative_spends WHERE opportunity_id=?', [
            opportunity,
          ]);
          expect(spends.map((row) => row['state']), ['shown']);
          if (round == 1) {
            expect(room.displays, hasLength(2));
            expect(int.tryParse(room.displays.first.ticket.id), isNotNull);
            expect(
              room.displays.last.ticket.id,
              room.displays.first.ticket.id,
              reason: 'both actual owner instances reused the same transient numeric UI ticket',
            );
          }
          final tickets = visit.database.select('SELECT * FROM memory_affinity_presentations WHERE opportunity_id=?', [
            opportunity,
          ]);
          expect(tickets, hasLength(1));
          final presentation = tickets.single['id']! as String;
          presentations.add(presentation);
          expect(tickets.single['character_id'], role);
          expect(requests, hasLength(round + 1));
          expect(requests.last['system'], companionMemoryFollowupPrompt);

          // Re-reporting this same actual receipt and answering source cannot
          // create a second presentation or an extra semantic interaction.
          store.recordCompanionPresentation(
            characterId: role,
            presentationId: presentation,
            kind: 'followup',
            presentedAtMs: shown['presented_at_ms']! as int,
            opportunityId: opportunity,
          );
          final answer = store.submitMessage(
            id: 'answer-$round',
            sessionId: store.lightSessionId,
            text: '刚做完了，谢谢你问起。',
            saidAtUtc: wall,
            offsetMinutes: 0,
            characterId: role,
          );
          for (final suffix in ['first', 'repeated']) {
            store.recordCompanionInteraction(
              characterId: role,
              eventId: 'answer-$round-$suffix',
              kind: 'answered_followup',
              atMs: wall,
              offsetMinutes: 0,
              sourceId: answer['id']! as String,
              presentationId: presentation,
            );
          }
          expect(
            visit.database.select("SELECT * FROM memory_affinity_events WHERE kind='answered_followup'"),
            hasLength(round + 1),
          );
        }
        expect(opportunities.toSet(), hasLength(2));
        expect(room.displays, hasLength(2));
        expect(room.lines, ['后来怎么样了？', '后来怎么样了？']);
        expect(presentations.toSet(), hasLength(2));
        expect(presentations, [for (final id in opportunities) 'followup:$id']);
        expect(visit.database.select('SELECT * FROM memory_affinity_presentations'), hasLength(2));
        expect(
          visit.database
              .select('SELECT followup_count FROM memory_affinity_days')
              .fold<int>(0, (total, row) => total + (row['followup_count']! as int)),
          2,
        );
        expect(store.requests(), hasLength(2));
        expect(
          store.requests().every(
            (row) => row['category'] == 'followup' && row['state'] == 'finished' && row['terminal'] == 'complete',
          ),
          isTrue,
        );
      } finally {
        await visit.close();
      }
    },
  );

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

  test('resident lease preserves the original turn across window detach and reattachment', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final signalEntered = Completer<void>();
    final signalRelease = Completer<void>();
    final signals = await _TerminalSignals.open();
    var wall = _now;
    var mono = 1000000;
    var physical = 0;
    const eventLine = '那边暂时没跑完，方便时再看看吧。';
    final visit = await _Visit.open(
      [
        _message(words: '我还在这儿。'),
        _message(words: jsonEncode({'action': 'silent'})),
        _message(words: jsonEncode({'action': 'line', 'text': eventLine})),
      ],
      beforeReply: (_) async {
        if (++physical == 1) {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        } else if (physical == 3) {
          signalEntered.complete();
          await signalRelease.future;
        }
      },
      connection: signals.connection,
      clock: () => CompanionInitiativeClock(wallMs: wall, monoMs: mono, offsetMinutes: 480),
    );
    const character = CompanionCharacter(name: '伙伴');
    const sourceKey = 'builtin:companion/whale-girl';
    visit.attachment.updateCharacter(character, const CompanionMoves(), sourceKey: sourceKey);
    final background = _NotificationUi(
      visit.agent,
      () => visit.container.read(companionInitiativeEnabledProvider) == true,
    );
    final resident = visit.agent.retainAlwaysOn(
      root: Future.value(visit.root),
      character: character,
      moves: const CompanionMoves(),
      sourceKey: sourceKey,
      ui: background,
      mapHandoff: CompanionMapHandoff(visit.container.read(companionMapsProvider)),
    );
    background.resident = resident;
    CompanionAgentAttachment? reopened;
    Future<void>? work;
    try {
      work = resident.submit('我先把页面收起来。');
      await entered.future;
      final source = visit.userSource;
      final turn = visit.turn;
      final role = resident.characterId;
      expect(role, isNotNull);
      expect(source['character_id'], role);
      expect(visit.attachment.affinity?.tier, 0);
      var affinityReads = 0;
      visit.database.trace = SqliteTraceCallback((event) {
        if (event is SqliteTraceStatement &&
            (event.sql?.startsWith('SELECT * FROM memory_affinity WHERE character_id=') ?? false)) {
          affinityReads++;
        }
        return 0;
      });
      try {
        for (var i = 0; i < 2; i++) {
          visit.agent.changed();
          expect(visit.attachment.affinity?.tier, 0);
        }
        expect(affinityReads, 0);
        expect(
          visit.memory.store.importCompanionAffinity(
            characterId: role!,
            sourceKind: 'host',
            sourceId: 'held-turn-affinity',
            closeness: 1,
            observedAtMs: _now,
            offsetMinutes: 480,
          ),
          isTrue,
        );
        affinityReads = 0; // Exclude the import's own read.
        visit.memory.changed();
        expect(visit.attachment.affinity?.tier, 5);
        expect(affinityReads, 1);
        expect(visit.agent.running, isTrue);
      } finally {
        visit.database.trace = null;
      }
      visit.attachment.detach();
      expect(visit.attachment.isAttached, isFalse);
      expect(resident.active, isTrue);
      expect(visit.agent.running, isTrue);
      release.complete();
      await work;
      expect(visit.requests, hasLength(1));
      expect(visit.calls('clock'), 1);
      expect(_context(visit.requests.single)['window'], 'notification');
      expect(visit.userSource, source);
      expect(visit.turn['id'], turn['id']);
      expect(visit.turn['closed'], 1);
      expect(visit.memory.store.requests().single['terminal'], 'complete');
      expect(resident.recentMessages.map((row) => row['text']), ['我先把页面收起来。', '我还在这儿。']);
      expect(resident.recentMessages.every((row) => row['character_id'] == role), isTrue);
      reopened = visit.agent.attach(
        root: Future.value(visit.root),
        character: character,
        moves: const CompanionMoves(),
        ui: _RoomUi(),
        mapHandoff: CompanionMapHandoff(visit.container.read(companionMapsProvider)),
      );
      expect(await reopened.openMemory(), same(visit.memory));
      expect(reopened.characterId, role);
      expect(reopened.affinity?.tier, 5);
      expect(reopened.text, '我还在这儿。');
      await visit.attachment.submit('旧窗口迟到的提交。');
      expect(visit.requests, hasLength(1));
      expect(visit.userSource, source);
      final previousSession = visit.memory.store.lightSessionId;
      final history = visit.memory.store.messages();
      final controlsBeforeRestart = background.controlChanges.length;
      await reopened.restart();
      expect(visit.memory.store.lightSessionId, isNot(previousSession));
      expect(resident.recentMessages, isEmpty);
      expect(reopened.text, isEmpty);
      expect(background.controlChanges, hasLength(controlsBeforeRestart + 1));
      expect(background.controlChanges.last, isFalse);
      expect(visit.memory.store.messages(), history);
      expect(visit.requests, hasLength(1));
      expect(visit.calls('clock'), 1);

      // The original lifecycle/source assertions above remain independent of
      // optional event speech. Now enable the real public consent and ingress.
      await visit.container.read(companionInitiativeEnabledProvider.notifier).set(true);
      visit.container.read(companionSignalConsentProvider);
      await _until(() => visit.container.read(companionSignalConsentProvider) != null);
      await visit.container
          .read(companionSignalConsentProvider.notifier)
          .set(const CompanionSignalConsent(state: true, optionalSpeech: true));
      final turnsBeforeEvents = visit.database.select('SELECT * FROM memory_agent_turns');
      final callsBeforeEvents = visit.database.select('SELECT * FROM memory_agent_calls');
      final firstReceiptId = visit.memory.store.requests().single['id'];
      reopened.observe(background.initiativeView);
      await signals.emit(visit.container);
      wall += 46000;
      mono += 46000;
      reopened.observe(background.initiativeView);
      await _until(
        () =>
            visit.requests.length == 2 &&
            !visit.agent.running &&
            visit.memory.store.requests().every((row) => row['state'] == 'finished'),
      );
      await Future<void>.delayed(Duration.zero);
      final silent = visit.memory.store.requests().singleWhere((row) => row['id'] != firstReceiptId);
      expect(silent['terminal'], 'complete');
      expect(silent['sent_at_ms'], isNotNull);
      expect(silent['input_uncached'], 12);
      expect(silent['output_tokens'], 8);
      expect(silent['raw_usage'], isNotNull);
      expect(background.delivered, isEmpty);
      expect(visit.database.select('SELECT * FROM memory_initiative_spends'), isEmpty);
      expect(visit.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
      expect(resident.preparingSignalId, isNull);

      await signals.emit(visit.container, reason: 'error');
      wall += 46000;
      mono += 46000;
      reopened.observe(background.initiativeView);
      await signalEntered.future.timeout(const Duration(seconds: 5));
      final preparingId = resident.preparingSignalId;
      expect(preparingId, isNotNull);
      expect(visit.agent.running, isTrue);
      expect(background.initiativeView.blocked, isFalse);
      // The same public observation as the periodic resident check must not
      // mistake its own model preparation for a different busy operation.
      reopened.observe(background.initiativeView);
      await Future<void>.delayed(Duration.zero);
      expect(resident.preparingSignalId, preparingId);
      expect(visit.agent.running, isTrue);
      expect(background.delivered, isEmpty);
      expect(visit.database.select('SELECT * FROM memory_initiative_spends'), isEmpty);
      signalRelease.complete();
      await background.entered.future.timeout(const Duration(seconds: 5));
      expect(background.delivered.single.text, eventLine);
      expect(background.delivered.single.id, 'task:${signals.deliveries.last.signal.id}');
      expect(visit.agent.running, isFalse);
      expect(resident.preparingSignalId, isNull);
      final lineReceipt = visit.memory.store.requests().singleWhere(
        (row) => row['id'] != firstReceiptId && row['id'] != silent['id'],
      );
      expect(lineReceipt['state'], 'finished');
      expect(lineReceipt['terminal'], 'complete');
      expect(lineReceipt['output_tokens'], 8);
      expect(visit.database.select('SELECT state FROM memory_initiative_spends').single['state'], 'reserved');
      background.acknowledgement.complete(true);
      await _until(
        () => visit.database.select('SELECT state FROM memory_initiative_spends').single['state'] == 'shown',
      );
      expect(visit.memory.store.initiativeRecord()!['signalAtMs'], hasLength(1));

      expect(visit.requests, hasLength(3));
      for (var index = 1; index < visit.requests.length; index++) {
        final body = visit.requests[index];
        expect(body.containsKey('tools'), isFalse);
        expect(body['max_tokens'], 800);
        expect(_context(body)['window'], 'notification');
        expect(_context(body)['taskObservation'], {
          'kind': 'task.terminal',
          'phase': index == 1 ? 'completed' : 'failed',
        });
        expect(jsonEncode(body), isNot(contains('s-photos')));
        expect(jsonEncode(body), isNot(contains('整理照片')));
      }
      expect(visit.memory.store.messages(), history);
      expect(visit.database.select('SELECT * FROM memory_agent_turns'), turnsBeforeEvents);
      expect(visit.database.select('SELECT * FROM memory_agent_calls'), callsBeforeEvents);
      expect(visit.memory.store.tasks(), isEmpty);
      expect(resident.recentMessages, isEmpty);
      expect(reopened.text, isEmpty);
      expect(visit.calls('clock'), 1);
    } finally {
      if (!release.isCompleted) release.complete();
      if (!signalRelease.isCompleted) signalRelease.complete();
      if (!background.acknowledgement.isCompleted) background.acknowledgement.complete(false);
      await work;
      reopened?.detach();
      resident.close();
      await visit.close();
      await signals.close();
    }
  });

  test('a newer resident input cancels a held request and a late reply cannot replace the new source', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final signalEntered = Completer<void>();
    final signalRelease = Completer<void>();
    final signals = await _TerminalSignals.open();
    var wall = _now;
    var mono = 1000000;
    var physical = 0;
    final visit = await _Visit.open(
      [
        _message(words: '迟到的旧回答。'),
        _message(words: '我听见新的话了。'),
        _message(words: jsonEncode({'action': 'line', 'text': '迟到的任务提示。'})),
        _message(words: '先听你这件事。'),
      ],
      beforeReply: (_) async {
        if (++physical == 1) {
          entered.complete();
          await release.future;
        } else if (physical == 3) {
          signalEntered.complete();
          await signalRelease.future;
        }
      },
      connection: signals.connection,
      clock: () => CompanionInitiativeClock(wallMs: wall, monoMs: mono, offsetMinutes: 480),
    );
    const character = CompanionCharacter(name: '伙伴');
    const sourceKey = 'builtin:companion/whale-girl';
    visit.attachment.updateCharacter(character, const CompanionMoves(), sourceKey: sourceKey);
    final background = _NotificationUi(
      visit.agent,
      () => visit.container.read(companionInitiativeEnabledProvider) == true,
    );
    final resident = visit.agent.retainAlwaysOn(
      root: Future.value(visit.root),
      character: character,
      moves: const CompanionMoves(),
      sourceKey: sourceKey,
      ui: background,
      mapHandoff: CompanionMapHandoff(visit.container.read(companionMapsProvider)),
    );
    background.resident = resident;
    Future<void>? old;
    try {
      old = resident.submit('第一句话。');
      await entered.future;
      final firstSource = visit.userSource;
      expect(_context(visit.requests.single)['window'], 'notification');
      await resident.submit('停一下，听这一句。', fromFloat: true);
      final newSourceId = visit.agent.sourceId;
      final newReplyId = visit.agent.replyId;
      expect(newSourceId, isNot(firstSource['id']));
      expect(visit.agent.text, '我听见新的话了。');
      expect(visit.requests, hasLength(2));
      release.complete();
      await old;
      // A later window cannot relabel the earlier request's captured origin.
      expect(visit.requests.map((request) => _context(request)['window']), ['notification', 'floating']);
      expect(visit.agent.sourceId, newSourceId);
      expect(visit.agent.replyId, newReplyId);
      expect(visit.agent.text, '我听见新的话了。');
      expect(visit.requests, hasLength(2));
      expect(visit.calls('clock'), 2);
      final history = visit.memory.store.messages();
      expect(history.where((row) => row['role'] == 'user').map((row) => row['text']), ['第一句话。', '停一下，听这一句。']);
      expect(history.where((row) => row['role'] == 'assistant').map((row) => row['text']), ['我听见新的话了。']);
      expect(visit.memory.store.requests().map((row) => row['terminal']), containsAll(['cancelled', 'complete']));
      expect(visit.memory.store.tasks(), isEmpty);
      expect(visit.database.select('SELECT * FROM memory_agent_calls'), isEmpty);

      await visit.container.read(companionInitiativeEnabledProvider.notifier).set(true);
      visit.container.read(companionSignalConsentProvider);
      await _until(() => visit.container.read(companionSignalConsentProvider) != null);
      await visit.container
          .read(companionSignalConsentProvider.notifier)
          .set(const CompanionSignalConsent(state: true, optionalSpeech: true));
      final receiptIds = visit.memory.store.requests().map((row) => row['id']).toSet();
      final turnsBeforeEvent = visit.database.select('SELECT * FROM memory_agent_turns');
      visit.attachment.observe(background.initiativeView);
      await signals.emit(visit.container);
      wall += 46000;
      mono += 46000;
      visit.attachment.observe(background.initiativeView);
      await signalEntered.future.timeout(const Duration(seconds: 5));
      final pendingReceipt = visit.memory.store.requests().singleWhere((row) => !receiptIds.contains(row['id']));
      expect(pendingReceipt['sent_at_ms'], isNotNull);
      expect(resident.preparingSignalId, isNotNull);
      expect(visit.agent.running, isTrue);
      expect(visit.memory.store.messages(), history);
      expect(visit.database.select('SELECT * FROM memory_agent_turns'), turnsBeforeEvent);
      expect(visit.database.select('SELECT * FROM memory_initiative_spends'), isEmpty);
      expect(visit.requests[2].containsKey('tools'), isFalse);
      expect(_context(visit.requests[2])['taskObservation'], {'kind': 'task.terminal', 'phase': 'completed'});

      // A real later user submission, not a test-only cancel callback, retires
      // the held event request and owns both the source and visible answer.
      visit.clockAt = wall;
      await resident.submit('先听我这件事。', fromFloat: true);
      final finalSourceId = visit.agent.sourceId;
      final finalReplyId = visit.agent.replyId;
      expect(finalSourceId, isNot(newSourceId));
      expect(visit.agent.text, '先听你这件事。');
      expect(resident.preparingSignalId, isNull);
      signalRelease.complete();
      await _until(() => !visit.agent.running && visit.memory.store.requests().every((row) => row['terminal'] != null));
      await Future<void>.delayed(Duration.zero);
      final cancelled = visit.memory.store.requests().singleWhere((row) => row['id'] == pendingReceipt['id']);
      expect(cancelled['state'], 'finished');
      expect(cancelled['terminal'], 'cancelled');
      expect(cancelled['sent_at_ms'], isNotNull);
      expect(visit.requests, hasLength(4));
      expect(visit.memory.store.requests(), hasLength(4));
      expect(_context(visit.requests[3])['window'], 'floating');
      expect(visit.agent.sourceId, finalSourceId);
      expect(visit.agent.replyId, finalReplyId);
      expect(visit.agent.text, '先听你这件事。');
      expect(background.delivered, isEmpty);
      expect(visit.database.select('SELECT * FROM memory_initiative_spends'), isEmpty);
      final after = visit.memory.store.messages();
      expect(after.where((row) => row['role'] == 'user').map((row) => row['text']), ['第一句话。', '停一下，听这一句。', '先听我这件事。']);
      expect(after.where((row) => row['role'] == 'assistant').map((row) => row['text']), ['我听见新的话了。', '先听你这件事。']);
      expect(visit.database.select('SELECT * FROM memory_agent_turns'), hasLength(turnsBeforeEvent.length + 1));
      expect(visit.database.select('SELECT * FROM memory_agent_calls'), isEmpty);
      expect(visit.memory.store.tasks(), isEmpty);
      expect(visit.calls('clock'), 3);
    } finally {
      if (!release.isCompleted) release.complete();
      if (!signalRelease.isCompleted) signalRelease.complete();
      if (!background.acknowledgement.isCompleted) background.acknowledgement.complete(false);
      await old;
      resident.close();
      await visit.close();
      await signals.close();
    }
  });

  test('screen observation revalidates after the model and awaits the actual presentation acknowledgement', () async {
    final visit = await _Visit.open([_message(words: '第一句观察。'), _message(words: '第二句观察。')]);
    const character = CompanionCharacter(name: '伙伴');
    const sourceKey = 'builtin:companion/whale-girl';
    visit.attachment.updateCharacter(character, const CompanionMoves(), sourceKey: sourceKey);
    final ambient = _AmbientUi();
    final resident = visit.agent.retainAlwaysOn(
      root: Future.value(visit.root),
      character: character,
      moves: const CompanionMoves(),
      sourceKey: sourceKey,
      ui: ambient,
      mapHandoff: CompanionMapHandoff(visit.container.read(companionMapsProvider)),
    );
    final validationTerminals = <Object?>[];
    Future<bool>? pending;
    final context = <String, Object?>{
      'type': 'screen_observation',
      'observed_at_ms': _now,
      'package_name': 'example.reader',
      'window_title': '阅读',
      'capture_method': 'tree',
      'text': '一段屏幕文字。',
      'emotion': 'neutral',
    };
    try {
      expect(await resident.openMemory(), same(visit.memory));
      expect(resident.characterId, isNotNull);
      final rejected = await visit.agent.observeScreen(
        context: context,
        isCurrentObservation: () async {
          validationTerminals.add(visit.memory.store.requests().single['terminal']);
          return false;
        },
      );
      expect(rejected, isFalse);
      expect(visit.requests, hasLength(1));
      expect(validationTerminals, ['complete']);
      expect(ambient.presented, isEmpty);
      expect(visit.agent.running, isFalse);
      final rejectedReceipt = visit.memory.store.requests().single;
      expect(rejectedReceipt['terminal'], 'complete');
      expect(visit.memory.store.messages(), isEmpty);
      expect(visit.memory.store.tasks(), isEmpty);

      ambient.entered = Completer<void>();
      ambient.acknowledgement = Completer<bool>();
      pending = visit.agent.observeScreen(
        context: context,
        isCurrentObservation: () async {
          final receipts = visit.memory.store.requests();
          validationTerminals.add(receipts.singleWhere((row) => row['id'] != rejectedReceipt['id'])['terminal']);
          return true;
        },
      );
      // Also finish this wait if the actual Agent exits before presentation,
      // so a regression fails the assertions instead of stranding teardown.
      await Future.any<void>([ambient.entered!.future, pending.then((_) {})]);
      expect(visit.requests, hasLength(2));
      expect(validationTerminals, ['complete', 'complete']);
      expect(ambient.presented, hasLength(1));
      expect(ambient.presented.single.text, '第二句观察。');
      expect(ambient.presented.single.emotion, 'neutral');
      expect(ambient.presented.single.speak, isTrue);
      expect(visit.agent.running, isTrue);
      final receipts = visit.memory.store.requests();
      expect(receipts, hasLength(2));
      expect(receipts.every((row) => row['terminal'] == 'complete'), isTrue);
      final shownReceipt = receipts.singleWhere((row) => row['id'] != rejectedReceipt['id']);
      expect(ambient.presented.single.id, 'screen-aside:${shownReceipt['id']}');
      ambient.acknowledgement!.complete(true);
      expect(await pending, isTrue);
      expect(visit.agent.running, isFalse);
      expect(visit.memory.store.messages(), isEmpty);
      expect(visit.memory.store.tasks(), isEmpty);
      for (final body in visit.requests) {
        expect(body.containsKey('tools'), isFalse);
        expect(_context(body)['screenObservation'], context);
      }

      // Observation text can be relevant without being a user's permission
      // to reopen a never topic. Seed only after the original empty-source
      // and acknowledgement assertions, using real public Store writes.
      final store = visit.memory.store;
      final coffeeSource = store.submitMessage(
        id: 'screen-coffee-source', sessionId: 'light:screen-test',
        characterId: resident.characterId,
        text: '我们聊过咖啡，散步时更轻松。', saidAtUtc: _now, offsetMinutes: 480,
      );
      final coffeeTurn = store.beginAgentTurn(
        messageId: coffeeSource['id']! as String,
        expectedSourceRev: coffeeSource['source_rev']! as int,
        shownCardRevisions: const {},
      )['id']! as String;
      final coffee = store.applyAgentMemoryTool(
        turnId: coffeeTurn, callId: 'screen-coffee', toolName: 'remember',
        input: {'collection': 'our_story', 'text': '我们聊过咖啡。', 'keywords': ['咖啡']},
      );
      expect(coffee.applied, isTrue);
      expect(store.applyAgentMemoryTool(
        turnId: coffeeTurn, callId: 'screen-coffee-never', toolName: 'quiet',
        input: {'card': coffee.targetId, 'mode': 'never'},
      ).applied, isTrue);
      final coffeeImpression = store.applyAgentMemoryTool(
        turnId: coffeeTurn, callId: 'screen-coffee-impression', toolName: 'impression',
        input: {'text': '聊过咖啡之后，散步时更轻松。', 'keywords': ['散步']},
      );
      expect(coffeeImpression.applied, isTrue);
      store.closeAgentTurn(coffeeTurn);
      final relevanceSource = store.submitMessage(
        id: 'screen-relevance-source', sessionId: 'light:screen-test',
        characterId: resident.characterId,
        text: '我们喜欢聊聊书里的想法，也喜欢聊聊路上的风景。', saidAtUtc: _now, offsetMinutes: 480,
      );
      final relevanceTurn = store.beginAgentTurn(
        messageId: relevanceSource['id']! as String,
        expectedSourceRev: relevanceSource['source_rev']! as int,
        shownCardRevisions: const {},
      )['id']! as String;
      final normal = store.applyAgentMemoryTool(
        turnId: relevanceTurn, callId: 'screen-relevant-normal', toolName: 'remember',
        input: {'collection': 'our_story', 'text': '我们喜欢聊聊书里的想法。', 'keywords': ['聊聊']},
      );
      final less = store.applyAgentMemoryTool(
        turnId: relevanceTurn, callId: 'screen-relevant-less', toolName: 'remember',
        input: {'collection': 'our_story', 'text': '我们喜欢聊聊路上的风景。', 'keywords': ['聊聊']},
      );
      expect(normal.applied, isTrue);
      expect(less.applied, isTrue);
      expect(store.applyAgentMemoryTool(
        turnId: relevanceTurn, callId: 'screen-relevance-less', toolName: 'quiet',
        input: {'card': less.targetId, 'mode': 'less'},
      ).applied, isTrue);
      store.closeAgentTurn(relevanceTurn);
      final screenCards = store.cards();
      expect(screenCards.singleWhere((row) => row['id'] == normal.targetId)['topic_mode'], 'normal');
      expect(screenCards.singleWhere((row) => row['id'] == less.targetId)['topic_mode'], 'less');
      expect(screenCards.singleWhere((row) => row['id'] == coffee.targetId)['topic_mode'], 'never');
      expect(screenCards.singleWhere((row) => row['id'] == coffeeImpression.targetId)['topic_id'],
        screenCards.singleWhere((row) => row['id'] == coffee.targetId)['topic_id']);
      final screenMessages = store.messages();
      final screenTasks = store.tasks();
      final screenControls = store.topicControls();
      final screenRequests = {for (final row in store.requests()) row['id']! as String: row};
      visit.memory.changed();
      visit.replies.add(_message(words: '书里的想法可以慢慢看。'));
      ambient.entered = null;
      ambient.acknowledgement = null;
      final invitingObservation = {...context, 'text': '聊聊咖啡'};
      expect(await visit.agent.observeScreen(
        context: invitingObservation, isCurrentObservation: () async => true,
      ), isTrue);
      expect(visit.requests, hasLength(3));
      final observationBody = visit.requests.last;
      expect(observationBody.containsKey('tools'), isFalse);
      expect(_context(observationBody)['screenObservation'], invitingObservation);
      final observationMemory = <Map>[
        for (final message in (observationBody['messages']! as List).cast<Map>())
          if (message['role'] == 'user' && message['content'] is List)
            for (final block in (message['content']! as List).cast<Map>())
              if (block['type'] == 'text' && (block['text']! as String).startsWith('{"type":"companion_memory"'))
                jsonDecode(block['text']! as String) as Map,
      ].single;
      final observationIds = (observationMemory['items']! as List).cast<Map>().map((row) => row['id']);
      expect(observationIds, unorderedEquals([normal.targetId, less.targetId]));
      expect(observationIds, isNot(contains(coffee.targetId)));
      expect(observationIds, isNot(contains(coffeeImpression.targetId)));
      expect(ambient.presented, hasLength(2));
      expect(ambient.presented.last.text, '书里的想法可以慢慢看。');
      expect(visit.agent.running, isFalse);
      expect(store.messages(), screenMessages);
      expect(store.tasks(), screenTasks);
      expect(store.cards(), screenCards);
      expect(store.topicControls(), screenControls);
      final afterObservation = {for (final row in store.requests()) row['id']! as String: row};
      expect(afterObservation, hasLength(3));
      for (final entry in screenRequests.entries) {
        expect(afterObservation[entry.key], entry.value);
      }
      final observationReceipt = afterObservation.entries.singleWhere((entry) => !screenRequests.containsKey(entry.key)).value;
      expect(observationReceipt['sent_at_ms'], isNotNull);
      expect(observationReceipt['terminal'], 'complete');
      expect(observationReceipt['input_uncached'], 12);
      expect(observationReceipt['output_tokens'], 8);
    } finally {
      final acknowledgement = ambient.acknowledgement;
      if (acknowledgement != null && !acknowledgement.isCompleted) acknowledgement.complete(true);
      await pending;
      resident.close();
      await visit.close();
    }
  });
}
