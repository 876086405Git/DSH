// A full room's reply state. Since A1 the room chats through the phone model
// loop in full mode too: the model's HTTP answer is synthetic, while the SSE
// reader, agent loop and tools, reply parser and page are real. A Host task
// Agent's approvals (now only on the tasks page) still use a synthetic watch
// transport with the real wire decoder, ChatController and CompanionAsk.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_host_tasks.dart' show CompanionNotesForegroundCapture;
import 'package:dsh_app/companion/companion_initiative.dart';
import 'package:dsh_app/companion/companion_initiative_owner.dart';
import 'package:dsh_app/companion/companion_keeper.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/companion/companion_widget.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/companion_agent_state.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/widgets/approval_card.dart';
import 'package:dsh_app/ui/companion/companion_ask.dart';
import 'package:dsh_app/ui/companion/companion_chrome.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/companion/companion_tasks_page.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'companion_test_settle.dart';
import 'initiative_memory.dart';
import 'phone_keeper_fake.dart';
import '../support/companion_notes_peer.dart'
    show
        HostModelRoute,
        NotesPeer,
        hostAgentPath,
        hostModelConnection,
        notesPath,
        notesAgreement,
        notesSnapshot,
        notesCapability;

const _session = 'c438-synthetic-session';
const _now = 1793937600000;

class _Bridge extends DshConnection {
  _Bridge() : super(Uri.parse('http://127.0.0.1:9'));

  /// The full room's model route (ADD67): the room asks this Host, which
  /// relays to the room's scripted model.
  DshConnection? host;
  DshHttpResponse json(Object body, [int status = 200]) =>
      DshHttpResponse(status, 'application/json', Uint8List.fromList(utf8.encode(jsonEncode(body))));
  int revision = 0;
  DshHttpResponse snapshot() => DshHttpResponse(
    200,
    'application/json',
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'storeId': 'c438-synthetic-store',
          'revision': revision,
          'memoryRevision': 0,
          'asOf': _now,
          'state': {'valence': 0.25, 'energy': 0.75, 'closeness': 0, 'activity': 'idle'},
        }),
      ),
    ),
  );
  @override
  Future<DshHttpResponse> get(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
    int? maxResponseBytes,
  }) async {
    if (path == hostAgentPath && host != null) {
      return host!.get(
        path,
        query: query,
        headers: headers,
        timeout: timeout,
        followRedirects: followRedirects,
        maxResponseBytes: maxResponseBytes,
      );
    }
    if (path == '$dshGoCompanionPath/memories') {
      return json({
        'v': 1,
        'storeId': '33333333-3333-4333-8333-333333333333',
        'revision': 0,
        'memoryRevision': 0,
        'memories': [],
      });
    }
    if (path != dshGoCompanionPath) {
      return json({
        'error': {'code': 'companion/not-found'},
      }, 404);
    }
    return snapshot();
  }

  @override
  Future<DshHttpResponse> getBounded(
    String path, {
    Map<String, String>? query,
    required int maxBytes,
    bool autoUncompress = false,
    Duration timeout = const Duration(seconds: 30),
  }) async => json({
    'error': {'code': 'companion/not-found'},
  }, 404);

  @override
  Future<DshHttpStreamResponse> postJsonStream(
    String path,
    Object? body, {
    required DshHttpAbort abort,
    Duration? headerTimeout,
    Duration? idleTimeout = const Duration(seconds: 20),
  }) {
    final relay = host;
    if (path == hostAgentPath && relay != null) {
      return relay.postJsonStream(
        path,
        body,
        abort: abort,
        headerTimeout: headerTimeout,
        idleTimeout: idleTimeout,
      );
    }
    return super.postJsonStream(path, body, abort: abort, headerTimeout: headerTimeout, idleTimeout: idleTimeout);
  }

  @override
  Future<DshHttpResponse> postJson(String path, Object? body, {Duration? timeout}) async {
    if (path == '/api/session/cancel') {
      return json({
        'ok': true,
        'value': {'accepted': true},
      });
    }
    revision++;
    return snapshot();
  }
}

class _Mux extends DshMux {
  _Mux(super.carrier);
  final connection = StreamController<DshConnectionState>.broadcast();
  @override
  Stream<DshConnectionState> get states => connection.stream;
}

// Only the physical peer is controlled. The ready handshake, RPC envelope,
// event identity, ChatController and actual Page approval callbacks are real.
class _ApprovalSocket extends StreamView<dynamic> implements WebSocket {
  _ApprovalSocket() : this._(StreamController<dynamic>());
  _ApprovalSocket._(this.incoming) : super(incoming.stream);
  final StreamController<dynamic> incoming;
  @override
  Duration? pingInterval;
  @override
  int? closeCode;
  @override
  String? closeReason;

  @override
  void add(dynamic data) {
    final frame = jsonDecode(data as String) as Map;
    if (frame['type'] == 'open') {
      expect(frame['endpoint'], r'$events');
      incoming.add(
        jsonEncode({
          'type': 'item',
          'streamId': frame['streamId'],
          'value': {
            'type': 'ready',
            'clientId': 'approval-peer',
            'host': {'home': '/fixture'},
          },
        }),
      );
    }
  }

  @override
  Future<void> close([int? code, String? reason]) {
    closeCode = code;
    closeReason = reason;
    return incoming.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ApprovalBridge extends _Bridge {
  final socket = _ApprovalSocket();
  final results = <Map<String, Object?>>[];
  final responded = Completer<void>();

  @override
  Future<WebSocket> connectWebSocket(String path, {Duration? timeout}) async {
    expect(path, remoteMuxPath);
    return socket;
  }

  @override
  Future<DshHttpResponse> postJson(String path, Object? body, {Duration? timeout}) async {
    if (path != r'/api/$events/result') {
      return super.postJson(path, body, timeout: timeout);
    }
    final envelope = Map<String, Object?>.from(body! as Map);
    results.add(envelope);
    if (!responded.isCompleted) {
      responded.complete();
    }
    return this.json({
      'type': 'server-response',
      'rpcId': envelope['rpcId'],
      'result': {'ok': true},
    });
  }
}

class _Client extends DshClient {
  _Client([_Bridge? bridge]) : super(bridge ?? _Bridge());
  final events = StreamController<DshEvent>();
  late final _fakeMux = _Mux(carrier);
  @override
  _Mux get mux => _fakeMux;
  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) {
    expect(sessionId, _session);
    return events.stream;
  }
}

/// The real saved bindings. A full turn resolves its Session for every model
/// round (ADD67), and after a memory control forgets the old one it opens a
/// new one: this Host opens it without its session RPCs.
class _HostSessions extends CompanionSessions {
  var opened = 0;

  @override
  Future<CompanionBinding> ensure({String? memoryArchiveId, int? memoryControlRevision}) async {
    final existing = of(HostRef.local);
    if (existing != null &&
        existing.full &&
        (memoryArchiveId == null ||
            (existing.memoryArchiveId == memoryArchiveId && existing.memoryControlRevision == memoryControlRevision))) {
      return existing;
    }
    final binding = CompanionBinding(
      '$_session-${++opened}',
      memoryArchiveId: memoryArchiveId,
      memoryControlRevision: memoryControlRevision,
    );
    state = {...state, '${HostRef.local.kind.name}:${HostRef.local.id}': binding};
    return binding;
  }
}

const _notesAgent = 'notes-task-agent';

class _NotesApprovalBridge extends _ApprovalBridge {
  MemoryRow? taskSnapshot;
  var taskReads = 0;
  var taskMissing = false;
  @override
  Future<DshHttpResponse> get(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
    int? maxResponseBytes,
  }) async {
    if (taskSnapshot != null && path == '$notesPath/${taskSnapshot!['taskId']}') {
      taskReads++;
      expect(query, {'hostStoreId': 'original-store'});
      if (taskMissing) {
        return this.json({
          'error': {'code': 'companion/task-not-found', 'message': 'No snapshot returned'},
        }, 404);
      }
      return this.json(taskSnapshot!);
    }
    return super.get(
      path,
      query: query,
      headers: headers,
      timeout: timeout,
      followRedirects: followRedirects,
      maxResponseBytes: maxResponseBytes,
    );
  }
}

class _NotesApprovalClient extends _Client {
  _NotesApprovalClient(super.bridge);
  final notesEvents = StreamController<DshEvent>.broadcast();
  final notesWatched = Completer<void>();
  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) {
    if (sessionId != _notesAgent) {
      return super.watch(sessionId, options: options);
    }
    if (!notesWatched.isCompleted) {
      notesWatched.complete();
    }
    return notesEvents.stream;
  }
}

/// Approval events and RPC use the existing real ChatController harness. Only
/// the foreground endpoint is sent through an actual numeric-loopback peer.
class _NotesForegroundBridge extends _NotesApprovalBridge {
  _NotesForegroundBridge(this.physical);
  final DshConnection physical;
  final closed = Completer<void>();
  DshHttpAbort? ownedAbort;
  Duration? observedIdle;
  final capabilityRead = Completer<void>();

  @override
  Future<DshHttpResponse> get(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
    int? maxResponseBytes,
  }) async {
    if (path == '$notesPath/capabilities') {
      if (!capabilityRead.isCompleted) capabilityRead.complete();
      return this.json({...notesCapability, 'notesForeground': true});
    }
    return super.get(
      path,
      query: query,
      headers: headers,
      timeout: timeout,
      followRedirects: followRedirects,
      maxResponseBytes: maxResponseBytes,
    );
  }

  @override
  Future<DshHttpStreamResponse> postJsonStream(
    String path,
    Object? body, {
    required DshHttpAbort abort,
    Duration? headerTimeout,
    Duration? idleTimeout = const Duration(seconds: 20),
  }) async {
    if (path == hostAgentPath) {
      return super.postJsonStream(path, body, abort: abort, headerTimeout: headerTimeout, idleTimeout: idleTimeout);
    }
    ownedAbort = abort;
    observedIdle = idleTimeout;
    final response = await physical.postJsonStream(
      path,
      body,
      abort: abort,
      headerTimeout: headerTimeout,
      idleTimeout: idleTimeout,
    );
    return DshHttpStreamResponse(response.statusCode, response.contentType, response.body, () async {
      await response.cancel();
      if (!closed.isCompleted) closed.complete();
    });
  }
}

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

const _followupLine = '对了，周四的面试后来怎么样啦？';
const _followupSource = '我周四打算去面试。周五你可以问我面试的进展。';

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true, apiKey: 'synthetic-test-key');
}

http.StreamedResponse _generated(String text) => http.StreamedResponse(
  Stream.value(
    utf8.encode(
      [
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': text},
        },
        {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'input_tokens': 40, 'output_tokens': 15},
        },
        {'type': 'message_stop'},
      ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
    ),
  ),
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

/// The memory worker's phone requests: the followup line, and an extraction
/// that changes nothing.
Future<http.StreamedResponse> _auxiliary(Map<String, Object?> body) async {
  if (body['system'] == companionMemoryFollowupPrompt) {
    return _generated(jsonEncode({'action': 'line', 'text': _followupLine}));
  }
  final input = jsonDecode(((body['messages']! as List).single as Map)['content'] as String) as Map;
  return _generated(
    jsonEncode({
      'schema_version': 2,
      'batch_id': input['batch_id'],
      'covered_message_ids': [for (final row in (input['source']! as List).cast<Map>()) row['id']],
      'completion': 'complete',
      'operations': [],
    }),
  );
}

/// The maintenance kind of a phone memory request, or null for any other.
String? _maintenanceKind(Map<String, Object?> body) {
  final messages = body['messages'];
  if (messages is! List || messages.isEmpty) return null;
  final content = (messages.first as Map)['content'];
  if (content is! String) return null;
  try {
    final context = jsonDecode(content);
    return context is Map && context['type'] == 'memory_maintenance_context' ? context['kind'] as String? : null;
  } on FormatException {
    return null;
  }
}

void _seedFullFollowup(CompanionMemoryOwner memory) {
  memory.store.submitMessage(
    id: 'full-followup-source',
    sessionId: _session,
    text: _followupSource,
    role: 'user',
    scope: 'real',
    saidAtUtc: DateTime.utc(2026, 11, 5, 12).millisecondsSinceEpoch,
    offsetMinutes: 0,
  );
  final batch = memory.store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
  final proposal = parseExtractionProposal(
    jsonEncode({
      'schema_version': 2,
      'batch_id': batch.id,
      'covered_message_ids': ['full-followup-source'],
      'completion': 'complete',
      'operations': [
        {
          'op': 'create',
          'kind': 'episode',
          'text': '我周四打算去面试',
          'keywords': ['面试'],
          'evidence': [
            {'message_id': 'full-followup-source', 'quote': _followupSource},
          ],
          'followup': {
            'local_date': '2026-11-06',
            'precision': 'day',
            'wording': '周五你可以问我面试的进展',
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
  _Room(this.root, {_Client? client, this.clock, this.initiative}) : client = client ?? _Client();
  final Directory root;
  final _Client client;
  final CompanionInitiativeClock Function()? clock;
  final _FollowupObserver? initiative;
  final phone = FakePhoneKeeper(state: FakePhoneKeeper.snapshotOf());
  late CompanionMemoryOwner memory;
  final commands = <(String, Map<String, Object?>)>[];
  CompanionStageEvents? events;
  late ProviderContainer container;
  late WidgetTester tester;
  String? speech(WidgetTester tester) => tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text;
  List<String> get emotionNames => [
    for (final c in commands)
      if (c.$1 == 'emotion') c.$2['name']! as String,
  ];
  List<String> get actionNames => [
    for (final c in commands)
      if (c.$1 == 'action') c.$2['name']! as String,
  ];

  // ── The room's model: asked through the Host in full mode (ADD67) ───────

  /// The Host this full room asks; it relays each request to [newClient].
  final host = HostModelRoute();

  /// Every request the room's model was asked, in order.
  final asked = <Map<String, Object?>>[];

  /// Chat requests' live Messages streams; the test writes each event.
  final replies = <StreamController<List<int>>>[];

  /// Answers the memory worker's own requests (followup wording, extraction).
  /// Null holds them unanswered.
  Future<http.StreamedResponse> Function(Map<String, Object?> body)? auxiliary = _auxiliary;

  http.Client newClient() => MockClient.streaming((request, body) async {
    final sent = jsonDecode(await body.bytesToString()) as Map<String, Object?>;
    asked.add(sent);
    final system = sent['system'];
    if (system == companionMemoryFollowupPrompt || system == companionMemoryExtractionPrompt) {
      final answer = auxiliary;
      if (answer != null) return answer(sent);
      return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
    }
    final reply = StreamController<List<int>>();
    replies.add(reply);
    return http.StreamedResponse(reply.stream, 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
  });

  List<Map<String, Object?>> get chats => [
    for (final body in asked)
      if (body['system'] != companionMemoryFollowupPrompt && body['system'] != companionMemoryExtractionPrompt) body,
  ];

  void event(Map<String, Object?> value) => replies.last.add(utf8.encode('data: ${jsonEncode(value)}\n\n'));

  /// Her words in content block [index] of the current request.
  void words(String text, {int index = 0}) => event({
    'type': 'content_block_delta',
    'index': index,
    'delta': {'type': 'text_delta', 'text': text},
  });

  /// One complete tool call in content block [index].
  void toolCall(int index, String id, String name, Map<String, Object?> input) {
    event({
      'type': 'content_block_start',
      'index': index,
      'content_block': {'type': 'tool_use', 'id': id, 'name': name, 'input': <String, Object?>{}},
    });
    event({
      'type': 'content_block_delta',
      'index': index,
      'delta': {'type': 'input_json_delta', 'partial_json': jsonEncode(input)},
    });
    event({'type': 'content_block_stop', 'index': index});
  }

  /// Ends the current request; a tool_use stop lets the loop continue.
  Future<void> end({String stop = 'end_turn'}) async {
    event({
      'type': 'message_delta',
      'delta': {'stop_reason': stop},
      'usage': {'output_tokens': 4},
    });
    event({'type': 'message_stop'});
    unawaited(replies.last.close());
    await drain();
  }

  /// The connection drops mid-reply.
  Future<void> drop() async {
    replies.last.addError(const SocketException('fixture connection reset'));
    unawaited(replies.last.close());
    await drain();
  }

  /// Real turns for the stream's cancel drain, then fake frames.
  Future<void> drain() async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    await flush(tester);
  }

  /// Waits until the loop has sent its [count]th chat request.
  Future<void> chatRequest(int count) async {
    for (var i = 0; i < 200 && chats.length < count; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(chats, hasLength(count));
    await flush(tester);
  }

  Future<void> send(String text) async {
    final before = chats.length;
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send')));
    await chatRequest(before + 1);
  }

  bool get running => tester.widget<CompanionComposer>(find.byType(CompanionComposer)).running;

  Future<void> open(WidgetTester tester, {void Function(CompanionMemoryOwner)? seed}) async {
    this.tester = tester;
    host.model = newClient;
    (client.connection as _Bridge).host = hostModelConnection(host);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    Directory('${root.path}/pack/runtime').createSync(recursive: true);
    Directory('${root.path}/pack/character').createSync(recursive: true);
    File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
    File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (clock != null) ...[companionInitiativeClockProvider.overrideWithValue(clock!), initiativeMemory(clock!)],
          if (initiative != null)
            companionInitiativeProvider.overrideWith((ref) {
              ref.onDispose(initiative!.dispose);
              return initiative!;
            }),
          activeHostProvider.overrideWith(_Host.new),
          activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: true))),
          companionSessionsProvider.overrideWith(_HostSessions.new),
          settingsProvider.overrideWith(_Settings.new),
          companionLightClientProvider.overrideWithValue(newClient),
          // A2 reads her vitals through the phone keeper in both room modes;
          // the real file keeper's I/O never completes on the fake clock.
          companionPhoneKeeperProvider.overrideWithValue((_) => phone),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('zh'),
          home: CompanionPage(
            storeOverride: CompanionPackStore(root),
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
            stageBuilder: (_, next) {
              events = next;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    for (var i = 0; i < 100 && events == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(events, isNotNull);
    container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
    // Load the real persisted binding before stage ready, as the global filter
    // can do in the application. Do not replace CompanionSessions or chatProvider.
    container.read(companionSessionsProvider);
    memory = await settleMixed(tester, container.read(companionMemoryOwnerProvider(root.absolute.path).future));
    await flush(tester);
    if (seed != null) {
      await settleMixed(tester, memory.migrateLocal());
      await settleMixed(tester, container.read(companionInitiativeProvider).ready);
      seed(memory);
    }
    expect(container.read(companionSessionsProvider.notifier).of(HostRef.local)?.sessionId, _session);
    events!.onReady();
    await flush(tester);
    // The room no longer watches its Host chat session.
    expect(container.exists(chatProvider(_session)), isFalse);
    commands.clear();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(() async {
      for (final reply in replies) {
        if (!reply.isClosed) await reply.close();
      }
      // Nothing listens to the Host chat watch any more; closing an unlistened
      // controller would wait for a listener forever.
      unawaited(client.events.close());
      await client.mux.connection.close();
      await client.close();
    });
  }
}

// Record accepted candidates and actual presentation calls without replacing
// the owner/controller, Page.canPresent or the SQLite reservation path.
class _FollowupObserver extends CompanionInitiative {
  _FollowupObserver(super.clock);
  final captured = <CompanionInitiativeSignal>[];
  var presentations = 0;

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
  }) {
    final accepted = super.requestSignal(
      room,
      view,
      candidate,
      isCurrent: isCurrent,
      present: (display) {
        if (followupId != null) presentations++;
        return present(display);
      },
      hide: hide,
      nightCareEnabled: nightCareEnabled,
      followupId: followupId,
      prepare: prepare,
      cancelPrepare: cancelPrepare,
      deliver: deliver,
      retainDelivery: retainDelivery,
      noticeEventId: noticeEventId,
      noticePersonId: noticePersonId,
      settled: settled,
    );
    if (accepted && followupId != null) captured.add(candidate);
    return accepted;
  }
}

Future<void> _captureFollowup(WidgetTester tester, _FollowupObserver observer) async {
  // Only fake test time advances: the actual greeting must end before Page can
  // capture the real opportunity, while the 45-second quiet gate stays closed.
  for (var second = 0; second < 15 && observer.captured.isEmpty; second++) {
    await tester.pump(const Duration(seconds: 1));
  }
  expect(observer.captured, hasLength(1));
  expect(observer.captured.single.nightKey, isNull);
  expect(observer.presentations, 0);
}

Future<void> flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 40));
  await tester.pump();
}

// Minimal relevant follow projection of a Host Agent session (A1: the notes
// task Agent; the room itself no longer has one): durable seq and stream
// revision/index stay contiguous; settlement logs the durable event first.
class _Wire {
  _Wire(this.session, this.add);
  final String session;
  final void Function(DshEvent) add;
  final frames = <Map<String, Object?>>[];
  int seq = -1;
  int revision = 0;
  int index = 0;
  int time = _now;
  int turn = 1;
  int step = 1;
  String attempt = '';
  String textSoFar = '';
  bool textOpen = false;
  List<Map<String, Object?>> stream = [];
  void frame(Map<String, Object?> frame) {
    frames.add(frame);
    final event = parseFollowFrame(session, frame);
    expect(event, isNot(isA<UnknownFrameEvent>()));
    add(event);
  }

  void log(String type, Map<String, Object?> data) => frame({
    'type': 'event',
    'event': {'type': type, 'seq': ++seq, 'time': time, 'data': data},
  });
  void beginTurn() {
    log('turn/start', {'turn': turn});
    log('step/start', {'turn': turn, 'step': step});
    log('user/message', {
      'id': 'user-$turn',
      'role': 'user',
      'content': [
        {'type': 'text', 'text': '说一句话。'},
      ],
      'source': {'kind': 'user', 'rpcId': 'request-$turn'},
    });
  }

  void start(String id) {
    attempt = id;
    index = 0;
    stream = [];
    textSoFar = '';
    textOpen = false;
    frame({
      'type': 'assistant-stream',
      'frame': {
        'type': 'start',
        'attemptId': attempt,
        'revision': ++revision,
        'turn': turn,
        'step': step,
        'startedAfterSeq': seq,
      },
    });
  }

  void chunk(Map<String, Object?> value) {
    stream.add({'type': 'chunk', 'time': time, 'chunk': value});
    frame({
      'type': 'assistant-stream',
      'frame': {
        'type': 'chunk',
        'attemptId': attempt,
        'revision': ++revision,
        'index': index++,
        'time': time,
        'chunk': value,
      },
    });
  }

  void text(String text) {
    if (textSoFar.isEmpty) {
      chunk({'type': 'block-start', 'index': 0, 'blockType': 'text'});
      textOpen = true;
    }
    textSoFar += text;
    chunk({'type': 'text-delta', 'index': 0, 'text': text});
  }

  void endText() {
    if (!textOpen) return;
    chunk({
      'type': 'block-end',
      'index': 0,
      'block': {'type': 'text', 'text': textSoFar},
    });
    textOpen = false;
  }

  void finish(String kind, [Map<String, Object?>? failure]) {
    if (kind == 'stop' || kind == 'tool-calls') endText();
    chunk({
      'type': 'finish',
      'reason': {'kind': kind, 'failure': ?failure},
    });
  }

  void settle(String type, {String? text, List<Map<String, Object?>> extraParts = const []}) {
    log(type, {
      'turn': turn,
      'step': step,
      'stream': List.of(stream),
      if (text != null)
        'message': {
          'id': 'message-$attempt',
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': text},
            ...extraParts,
          ],
          'source': {'kind': 'model', 'provider': 'synthetic', 'model': 'synthetic'},
        },
    });
    frame({
      'type': 'assistant-stream',
      'frame': {
        'type': 'end',
        'attemptId': attempt,
        'revision': ++revision,
        'index': index,
        'outcome': {'kind': 'committed', 'eventType': type, 'seq': seq},
      },
    });
  }

  void endTurn() {
    log('step/end', {'turn': turn, 'step': step});
    log('turn/end', {
      'turn': turn,
      'reason': {'kind': 'completed'},
    });
  }
}

void main() {
  late Directory temporary;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('c438-stream-');
    final memory = CompanionMemoryStore(sqlite3.open('${temporary.path}/memory.sqlite'), nowMilliseconds: () => _now);
    SharedPreferences.setMockInitialValues({
      'companion_sessions': jsonEncode({
        '${HostRef.local.kind.name}:${HostRef.local.id}': {
          'id': _session,
          'full': true,
          'memoryArchiveId': memory.archive['id'],
          'memoryControlRevision': memory.archive['control_revision'],
        },
      }),
    });
    memory.close();
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  // A full room drafts its followup wording with the same request as light
  // mode, now asked through its Host (ADD67) rather than the phone key.
  // (The old approval variant: an approval no longer opens in the room, it
  // lives on the tasks page, so the room is covered by that route instead.)
  for (final covered in [false, true]) {
    testWidgets('full Page drafts its actual followup through the phone memory route, covered=$covered', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setBool('companion_initiative_enabled', true);
        await preferences.setString('companion_initiative_pace', 'often');
        await preferences.setString('companion_persona_v1', jsonEncode({'custom': '说话简短温和。', 'callMe': '阿禾'}));
      });
      final start = tester.binding.clock.now();
      CompanionInitiativeClock clock() => CompanionInitiativeClock(
        wallMs:
            DateTime.utc(2026, 11, 6, 12).millisecondsSinceEpoch +
            tester.binding.clock.now().difference(start).inMilliseconds,
        monoMs: tester.binding.clock.now().difference(start).inMilliseconds,
      );
      final room = _Room(temporary, clock: clock);
      final release = Completer<void>();
      room.auxiliary = (body) async {
        if (body['system'] == companionMemoryFollowupPrompt) await release.future;
        return _auxiliary(body);
      };
      List<Map<String, Object?>> followups() => [
        for (final body in room.asked)
          if (body['system'] == companionMemoryFollowupPrompt) body,
      ];
      String? speech() => tester.widget<CompanionSpeech>(find.byType(CompanionSpeech, skipOffstage: false)).text;
      await room.open(tester, seed: _seedFullFollowup);
      try {
        for (var i = 0; i < 120 && followups().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump(const Duration(seconds: 1));
        }
        expect(followups(), hasLength(1));
        final sent = followups().single;
        expect(sent['model'], 'deepseek-flash');
        expect(sent['max_tokens'], 128);
        expect(sent.containsKey('tools'), isFalse);
        final input = jsonDecode(((sent['messages']! as List).single as Map)['content'] as String) as Map;
        expect(input['card'], {'text': '我周四打算去面试'});
        expect(input['invitation'], {
          'message_id': 'full-followup-source',
          'source_rev': 1,
          'said_at_utc': '2026-11-05T12:00:00.000Z',
          'offset_minutes': 0,
          'quote': _followupSource,
        });
        expect(input['persona'], allOf(contains('说话简短温和。'), contains('阿禾')));
        expect(input['support'], isEmpty);
        expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
        final held = room.memory.store.requests().where((row) => row['category'] == 'followup').single;
        expect(held['sent_at_ms'], isNotNull);
        expect(held['raw_usage'], isNull);
        expect(speech(), isNot(_followupLine));

        if (covered) {
          unawaited(
            Navigator.of(tester.element(find.byType(CompanionPage)))
                .push<void>(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('另外的页面')))),
          );
          await tester.pumpAndSettle();
        }
        release.complete();
        await room.drain();
        for (var i = 0; i < 20 && speech() != _followupLine; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump(const Duration(milliseconds: 50));
        }
        final receipt = room.memory.store.requests().where((row) => row['category'] == 'followup').single;
        expect(receipt['provider'], 'deepseek');
        expect(receipt['state'], 'finished');
        expect(receipt['raw_usage'], isNotNull);
        expect(((receipt['raw_usage']! as Map)['final_usage'] as Map)['output_tokens'], 15);
        if (covered) {
          expect(speech(), isNot(_followupLine));
          expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
        } else {
          expect(speech(), _followupLine);
          expect(room.memory.store.initiativeRecord()!['signalAtMs'], hasLength(1));
          expect(room.memory.store.nextFollowup(nowMs: clock().wallMs), isNull);
        }
        expect(followups(), hasLength(1));
        // ADD67: the full room's wording request goes through its Host.
        expect([for (final body in room.host.requests) body['kind']], contains('followup'));
        expect(
          room.memory.store.messages().where((row) => row['role'] == 'assistant'),
          isEmpty,
          reason: 'auxiliary wording is not a committed ordinary chat turn',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await room.close(tester);
      }
    });
  }

  // A1: the correction is the model's own revise call in the next turn; the
  // late words of the turn it replaced must not speak or write a last line.
  testWidgets('fixture 4 a composer correction retires a late full reply before speech and last-line writes', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('companion_voice_enabled', true);
      await prefs.setString('companion_voice_v1', '{"source":"system"}');
    });
    const voiceChannel = MethodChannel('dsh/companion_voice');
    const widgetChannel = MethodChannel('dsh/companion_widget');
    final voiceCalls = <MethodCall>[];
    final updates = <Map<String, Object?>>[];
    final native = <String, Object?>{};
    final voiceReady = Completer<void>();
    final cleared = Completer<void>();
    int? controlBefore;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(voiceChannel, (call) async {
      voiceCalls.add(call);
      if (call.method == 'ready' && !voiceReady.isCompleted) voiceReady.complete();
      return switch (call.method) {
        'ready' || 'speak' => true,
        _ => null,
      };
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(widgetChannel, (call) async {
      final values = Map<String, Object?>.from(call.arguments as Map);
      updates.add(values);
      for (final entry in values.entries) {
        if (entry.value == null) {
          native.remove(entry.key);
        } else {
          native[entry.key] = entry.value;
        }
      }
      final before = controlBefore;
      if (before != null &&
          (values['memoryControlRevision'] as int? ?? -1) > before &&
          values.containsKey('line') &&
          values['line'] == null &&
          values.containsKey('saidAt') &&
          values['saidAt'] == null &&
          !cleared.isCompleted) {
        cleared.complete();
      }
      return true;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(voiceChannel, null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(widgetChannel, null);
    });
    final room = _Room(temporary);
    late String card;
    await room.open(
      tester,
      seed: (memory) {
        const original = '我琴课一直在周四。';
        memory.store.submitMessage(
          id: 'lesson-original',
          sessionId: memory.store.lightSessionId,
          text: original,
          saidAtUtc: _now,
          offsetMinutes: 0,
        );
        final batch = memory.store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
        final proposal = parseExtractionProposal(
          jsonEncode({
            'schema_version': 2,
            'batch_id': batch.id,
            'covered_message_ids': ['lesson-original'],
            'completion': 'complete',
            'operations': [
              {
                'op': 'create',
                'kind': 'fact',
                'text': original,
                'keywords': ['琴课'],
                'evidence': [
                  {'message_id': 'lesson-original', 'quote': original},
                ],
              },
            ],
          }),
          batch,
        );
        expect(memory.store.commitExtraction(batch, proposal), isTrue);
        card = memory.store.cards().single['id']! as String;
        memory.changed();
      },
    );
    try {
      await settleMixed(tester, voiceReady.future);
      await flush(tester);
      await room.send('说一句话。');
      const prefix = '我记得琴课在周四。';
      room.words(prefix);
      await flush(tester);
      expect(room.running, isTrue);
      expect(room.speech(tester), prefix);
      final oldSpeech =
          voiceCalls
                  .where((call) => call.method == 'speak' && (call.arguments as Map)['text'] == prefix)
                  .single
                  .arguments
              as Map;
      final stops = voiceCalls.where((call) => call.method == 'stop').length;
      final before = room.memory.store.archive['control_revision']! as int;
      controlBefore = before;
      final late = room.replies.first;
      const correction = '琴课改成我琴课一直在周五。';
      await room.send(correction);
      expect(jsonEncode(room.chats.last['messages']), contains(card));
      room.toolCall(0, 'call-revise', 'revise', {
        'card': card,
        'text': '我琴课一直在周五。',
        'keywords': ['琴课'],
      });
      await room.end(stop: 'tool_use');
      await room.chatRequest(3);
      room.words('啊，是我记岔了。');
      await room.end();
      await settleMixed(tester, cleared.future);
      await flush(tester);
      expect(room.memory.store.archive['control_revision'], before + 1);
      expect(room.memory.store.archive['widget_clear_pending'], 0);
      expect(room.memory.store.cards().single['text'], '我琴课一直在周五。');
      final source = room.memory.store.messages().singleWhere((row) => row['text'] == correction);
      final evidence = (room.memory.store.cards().single['evidence'] as List).cast<Map>();
      expect(evidence.single['message_id'], source['id']);
      expect(evidence.single['source_rev'], source['source_rev']);
      expect(evidence.single['quote'], correction);
      expect(voiceCalls.where((call) => call.method == 'stop').length, greaterThan(stops));
      expect(room.speech(tester), '啊，是我记岔了。');
      expect(native.containsKey('line'), isFalse);
      expect(native.containsKey('saidAt'), isFalse);
      final speaks = voiceCalls.where((call) => call.method == 'speak').length;
      final mouth = room.commands.where((command) => command.$1 == 'say').length;
      final writes = updates.length;
      // Even a native callback for the already stopped prefix must stay old.
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        voiceChannel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall('event', {'type': 'start', 'id': oldSpeech['id']})),
        (_) {},
      );
      const lateWords = '旧回复晚到，还是周四。';
      if (!late.isClosed) {
        late.add(
          utf8.encode(
            'data: ${jsonEncode({
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': lateWords},
            })}\n\n',
          ),
        );
      }
      await room.drain();
      expect(room.speech(tester), '啊，是我记岔了。');
      expect(voiceCalls.where((call) => call.method == 'speak').length, speaks);
      expect(room.commands.where((command) => command.$1 == 'say').length, mouth);
      expect(updates.skip(writes).where((value) => value['line'] != null), isEmpty);
      expect(native.containsKey('line'), isFalse);
      expect(native.containsKey('saidAt'), isFalse);
      expect(room.memory.store.messages().any((row) => (row['text']! as String).contains(lateWords)), isFalse);
      expect(room.memory.select('琴课在什么时候').block, allOf(contains('周五'), isNot(contains('周四'))));
      // A metadata-only write waits behind the real widget queue without
      // clearing a late line and thereby hiding a broken Page gate.
      expect(
        await settleMixed(
          tester,
          room.container.read(companionWidgetProvider).update({
            'memoryArchiveId': room.memory.store.archive['id'],
            'memoryControlRevision': room.memory.store.archive['control_revision'],
          }),
        ),
        isTrue,
      );
      expect(updates.skip(writes).where((value) => value['line'] != null), isEmpty);
      expect(native.containsKey('line'), isFalse);
      expect(native.containsKey('saidAt'), isFalse);
    } finally {
      await room.close(tester);
    }
  });

  // A1: approvals are answered on the tasks page now; that route covering
  // the room is what holds a captured followup back.
  testWidgets('fixture 10 a captured followup waits while the tasks page covers the room', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final started = tester.binding.clock.now();
    final wall = DateTime.utc(2026, 11, 6, 12).millisecondsSinceEpoch;
    CompanionInitiativeClock clock() {
      final elapsed = tester.binding.clock.now().difference(started).inMilliseconds;
      return CompanionInitiativeClock(wallMs: wall + elapsed, monoMs: elapsed);
    }

    final observer = _FollowupObserver(clock);
    final room = _Room(temporary, clock: clock, initiative: observer);
    await room.open(tester, seed: _seedFullFollowup);
    try {
      await _captureFollowup(tester, observer);
      expect(room.asked, isEmpty);
      expect(room.memory.store.followups().single['state'], 'pending');
      expect(room.running, isFalse);
      unawaited(
        Navigator.of(tester.element(find.byType(CompanionPage)))
            .push<void>(MaterialPageRoute(builder: (_) => CompanionTasksPage(memory: room.memory))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(CompanionTasksPage), findsOneWidget);
      for (var second = 0; second < 60; second++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(CompanionTasksPage), findsOneWidget);
      expect(observer.presentations, 0);
      expect(room.asked, isEmpty);
      expect(room.memory.store.followups().single['state'], 'pending');
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
      expect(room.memory.store.initiativeRecord()!['inviteAtMs'], isEmpty);
      expect(room.memory.store.requests(), isEmpty);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('fixture 10 a captured followup is not shown after the actual clock reaches 23', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final started = tester.binding.clock.now();
    final wall = DateTime.utc(2026, 11, 6, 22, 59, 30).millisecondsSinceEpoch;
    CompanionInitiativeClock clock() {
      final elapsed = tester.binding.clock.now().difference(started).inMilliseconds;
      return CompanionInitiativeClock(wallMs: wall + elapsed, monoMs: elapsed);
    }

    final observer = _FollowupObserver(clock);
    final room = _Room(temporary, clock: clock, initiative: observer);
    await room.open(tester, seed: _seedFullFollowup);
    try {
      await _captureFollowup(tester, observer);
      expect(room.asked, isEmpty);
      expect(companionNightKey(clock().wallMs, clock().offsetMinutes), isNull);
      expect(room.running, isFalse);
      for (var second = 0; second < 60; second++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(companionNightKey(clock().wallMs, clock().offsetMinutes), '2026-11-06');
      expect(observer.presentations, 0);
      expect(room.speech(tester), isNot(_followupLine));
      // A2: the one-minute idle tick runs the maintenance lane, which organizes
      // the completed source day (2026-11-05) whatever the hour. That is the
      // only phone request; no followup wording is ever drafted.
      expect(room.asked.map(_maintenanceKind), ['organize']);
      expect([for (final body in room.asked) body['system']], isNot(contains(companionMemoryFollowupPrompt)));
      expect([for (final body in room.host.requests) body['kind']], isNot(contains('followup')));
      expect(room.memory.store.followups().single['state'], 'pending');
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
      expect(room.memory.store.initiativeRecord()!['inviteAtMs'], isEmpty);
      // The usage journal holds only that maintenance reservation.
      expect([for (final row in room.memory.store.requests()) row['category']], ['organize']);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('positive control: empty start, monotonic chunks and repeated status preserve one reply', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      await room.send('说一句话。');
      expect(room.memory.store.messages().where((row) => row['role'] == 'assistant'), isEmpty);
      room.words('[表情:开心]你');
      await flush(tester);
      expect(room.speech(tester), '你');
      room.words('好。');
      await flush(tester);
      expect(room.speech(tester), '你好。');
      final says = room.commands.where((c) => c.$1 == 'say').length;
      for (var i = 0; i < 3; i++) {
        // The process-level agent repeats its unchanged running state.
        room.container.read(companionAgentProvider).changed();
        await flush(tester);
      }
      expect(room.commands.where((c) => c.$1 == 'say').length, says);
      expect(room.emotionNames, ['happy']);
      await room.end();
      expect(room.running, isFalse);
      expect(room.speech(tester), '你好。');
      expect(room.emotionNames, ['happy']);
      expect(room.memory.store.messages().where((row) => row['role'] == 'assistant').single['text'], '[表情:开心]你好。');
    } finally {
      await room.close(tester);
    }
  });

  for (final outcome in ['allow', 'ask-ai', 'another-route', 'replacement', 'fresh-allow']) {
    testWidgets('F foreground keeps only its original approval risk route: $outcome', (tester) async {
      final peer = (await tester.runAsync(NotesPeer.open))!;
      final bridge = _NotesForegroundBridge(peer.client.connection);
      final client = _NotesApprovalClient(bridge);
      final room = _Room(temporary, client: client);
      final hostKey = '${HostRef.local.kind.name}:${HostRef.local.id}';
      late String id;
      late MemoryRow create;
      late HttpResponse held;
      final release = Completer<void>();
      final imported = Completer<void>();
      var foregroundPosts = 0;
      MemoryRow approval(String event) => {
        'taskRev': 1,
        'stepKey': 'model',
        'agentId': _notesAgent,
        'approvalId': 'engine-approval-$event',
        'eventId': 'gateway-$event',
        'callId': 'call-$event',
      };
      MemoryRow awaiting(String event, int seq) => {
        ...notesSnapshot(
          create,
          state: 'waiting',
          seq: seq,
          approval: approval(event),
          steps: [
            {
              'taskRev': 1,
              'stepKey': 'model',
              'attemptId': 'foreground-model',
              'state': 'waiting',
              'startedAtMs': _now,
              'finishedAtMs': null,
              'reason': 'approval_required',
              'result': null,
            },
          ],
        ),
        'waitReason': 'approval_required',
      };
      void engineApproval(String event) => client.notesEvents.add(
        HostEvent.fromFrame({
          'type': 'waterfall',
          'event': 'approval/request',
          'eventId': 'gateway-$event',
          'agentId': _notesAgent,
          'request': {'toolName': 'web_fetch', 'callId': 'call-$event'},
        }),
      );
      peer.respond = (request, _) async {
        foregroundPosts++;
        bridge.taskSnapshot = awaiting('E1', 2);
        held = request.response
          ..bufferOutput = false
          ..headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
        held.write('${jsonEncode(bridge.taskSnapshot)}\n');
        await held.flush();
        await release.future;
        try {
          await held.close();
        } on Object {
          // The actual SDK abort closes this particular HTTP response.
        }
      };
      await room.open(
        tester,
        seed: (memory) {
          memory.store.submitMessage(
            id: 'foreground-source',
            sessionId: 'full:$hostKey',
            text: '请电脑整理今天的笔记，离开这里就先停',
            saidAtUtc: _now,
            offsetMinutes: 480,
            zoneId: 'Asia/Shanghai',
            offsetSeconds: 28800,
          );
          final task = memory.store.createNotesTaskFromMessage(
            messageId: 'foreground-source',
            expectedSourceRev: 1,
            itemNo: 0,
            roomMode: 'full',
            hostKey: hostKey,
            hostSessionId: _session,
            agreement: notesAgreement(afterExit: 'pause'),
          );
          id = task['task_id']! as String;
          create =
              memory.store.prepareHostTaskOperation(
                    taskId: id,
                    taskRev: 1,
                    hostKey: hostKey,
                    hostStoreId: 'original-store',
                    initialOpportunity: true,
                  )!['request']!
                  as MemoryRow;
          bridge.taskSnapshot = {...notesSnapshot(create, state: 'waiting'), 'waitReason': 'foreground_required'};
        },
      );
      void changed() {
        final snapshot = room.memory.store.hostTask(id)!['snapshot'] as MemoryRow?;
        if ((snapshot?['approval'] as MemoryRow?)?['eventId'] == 'gateway-E1' && !imported.isCompleted) {
          imported.complete();
        }
      }

      room.memory.addListener(changed);
      try {
        final fresh = <CompanionNotesForegroundCapture>[];
        if (outcome == 'fresh-allow') {
          final capability = (await settleMixed(tester, client.readCompanionTasksCapability()))!;
          final snapshot = (await settleMixed(
            tester,
            client.readCompanionHostTask(hostStoreId: 'original-store', taskId: id),
          ))!;
          final captured = room.memory.store.importHostTaskSnapshot(taskId: id, hostKey: hostKey, snapshot: snapshot);
          fresh.add((task: captured, client: client, capability: capability));
        }
        unawaited(
          Navigator.of(tester.element(find.byType(CompanionPage))).push<void>(
            MaterialPageRoute(
              builder: (_) => CompanionTasksPage(memory: room.memory, taskId: id, freshNotes: fresh),
            ),
          ),
        );
        await tester.pump();
        await settleMixed(tester, bridge.capabilityRead.future);
        await tester.pumpAndSettle();
        if (outcome != 'fresh-allow') {
          expect(foregroundPosts, 0);
          await tester.ensureVisible(find.text('在这里继续'));
          await tester.tap(find.text('在这里继续'));
        }
        await settleMixed(tester, imported.future);
        await settleMixed(tester, client.notesWatched.future);
        client.notesEvents.add(
          parseFollowFrame(_notesAgent, {
            'type': 'snapshot',
            'cursor': -1,
            'records': [],
            'assistantStream': {'revision': 0},
          }),
        );
        engineApproval('E1');
        await flush(tester);
        await tester.pump(CompanionAsk.detailWait);
        await tester.pumpAndSettle();
        final old = tester.widget<ApprovalCard>(find.byType(ApprovalCard));
        expect(old.request.eventId, 'gateway-E1');
        expect(old.request.sessionId, _notesAgent);
        expect(bridge.ownedAbort, isNotNull);
        expect(bridge.observedIdle, isNull);
        await tester.ensureVisible(find.widgetWithText(TextButton, '本对话都允许'));
        await tester.tap(find.widgetWithText(TextButton, '本对话都允许'));
        await flush(tester);
        await tester.pumpAndSettle();
        expect(find.text('本对话都允许？'), findsOneWidget);
        final sheet = ModalRoute.of(tester.element(find.byKey(const ValueKey('risk-confirm'))))!;
        expect(sheet.isCurrent, isTrue);
        expect(bridge.ownedAbort!.isAborted, isFalse);
        expect(bridge.results, isEmpty);
        await tester.pump(const Duration(seconds: 30));
        expect(bridge.ownedAbort!.isAborted, isFalse);

        if (outcome == 'allow' || outcome == 'fresh-allow') {
          await tester.tap(find.byKey(const ValueKey('risk-confirm')));
          await settleMixed(tester, bridge.responded.future);
          await tester.pumpAndSettle();
          expect(bridge.ownedAbort!.isAborted, isFalse);
          expect(room.container.read(chatProvider(_notesAgent)).autoApprove, isTrue);
          expect((bridge.results.single['payload']! as MemoryRow)['args'], {
            'clientId': 'approval-peer',
            'eventId': 'gateway-E1',
            'outcome': {'kind': 'result', 'value': ApprovalDecision.allowOnce.wire},
          });
        } else if (outcome == 'ask-ai') {
          await tester.tap(find.byKey(const ValueKey('ask-ai-link')));
          await tester.pumpAndSettle();
          await settleMixed(tester, bridge.closed.future);
          expect(find.byType(CompanionTasksPage), findsNothing);
          expect(room.container.read(composeInboxProvider).single.text, contains('本对话都允许'));
          expect(bridge.results, isEmpty);
        } else if (outcome == 'another-route') {
          // A different route pushed while the exact risk Future is pending
          // is not covered by that sheet's owner exception.
          unawaited(
            Navigator.of(tester.element(find.byKey(const ValueKey('risk-confirm'))))
                .push<void>(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('另外的页面')))),
          );
          await tester.pumpAndSettle();
          await settleMixed(tester, bridge.closed.future);
          expect(sheet.isCurrent, isFalse);
          expect(bridge.results, isEmpty);
        } else {
          client.notesEvents.add(HostEvent.fromFrame({'type': 'cancel', 'eventId': 'gateway-E1'}));
          engineApproval('E2');
          bridge.taskSnapshot = awaiting('E2', 3);
          await settleMixed(tester, () async {
            held.write('${jsonEncode(bridge.taskSnapshot)}\n');
            await held.flush();
          }());
          await settleMixed(tester, bridge.closed.future);
          await tester.tap(find.byKey(const ValueKey('risk-confirm')));
          await tester.pumpAndSettle();
          await settleMixed(tester, old.onRespond(old.request, ApprovalDecision.allowOnce));
          await settleMixed(tester, old.onAllowAll!(old.request));
          expect(bridge.results, isEmpty);
          expect(room.container.read(chatProvider(_notesAgent)).autoApprove, isFalse);
          expect((room.memory.store.hostTask(id)!['snapshot']! as MemoryRow)['approval'], approval('E2'));
        }
        expect(foregroundPosts, 1);
        expect(peer.calls.single.uri.path, '$notesPath/$id/foreground');
        expect(peer.calls.single.body, {
          'v': 1,
          'hostStoreId': 'original-store',
          'hostExecutionId': 'actual-execution',
          'taskRev': 1,
          'sourceSessionId': 'full:$hostKey',
        });
        expect(room.memory.store.hostTaskCommands(id), hasLength(1));
        expect(room.memory.store.hostTask(id)!['task_rev'], 1);
      } finally {
        room.memory.removeListener(changed);
        if (!release.isCompleted) release.complete();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        if (bridge.ownedAbort != null) await settleMixed(tester, bridge.closed.future);
        await settleMixed(tester, client.notesEvents.close());
        unawaited(client.events.close());
        await settleMixed(tester, client.mux.connection.close());
        await settleMixed(tester, client.close());
        await settleMixed(tester, peer.close());
        await tester.pump(const Duration(seconds: 16));
      }
    });
  }

  for (final outcome in ['allow', 'cancel', 'missing']) {
    testWidgets('F task page binds the original Agent approval and rejects stale evidence: $outcome', (tester) async {
      final bridge = _NotesApprovalBridge();
      final client = _NotesApprovalClient(bridge);
      final room = _Room(temporary, client: client);
      final hostKey = '${HostRef.local.kind.name}:${HostRef.local.id}';
      late String id;
      late MemoryRow create;
      MemoryRow approval(String event) => {
        'taskRev': 1,
        'stepKey': 'model',
        'agentId': _notesAgent,
        'approvalId': 'engine-approval-$event',
        'eventId': 'gateway-$event',
        'callId': 'call-$event',
      };
      void hostSnapshot(String event, int seq) {
        bridge.taskSnapshot = {
          ...notesSnapshot(
            create,
            state: 'waiting',
            seq: seq,
            approval: approval(event),
            steps: [
              {
                'taskRev': 1,
                'stepKey': 'model',
                'attemptId': 'model-wait',
                'state': 'waiting',
                'startedAtMs': _now,
                'finishedAtMs': null,
                'reason': 'approval_required',
                'result': null,
              },
            ],
          ),
          'waitReason': 'approval_required',
        };
      }

      void engineApproval(String event) => client.notesEvents.add(
        HostEvent.fromFrame({
          'type': 'waterfall',
          'event': 'approval/request',
          'eventId': 'gateway-$event',
          'agentId': _notesAgent,
          'request': {'toolName': 'web_fetch', 'callId': 'call-$event'},
        }),
      );
      await room.open(
        tester,
        seed: (memory) {
          memory.store.submitMessage(
            id: 'notes-source',
            sessionId: 'full:$hostKey',
            text: '请电脑把2026-11-21的笔记整理成一页待办，原件别动',
            saidAtUtc: _now,
            offsetMinutes: 480,
            zoneId: 'Asia/Shanghai',
            offsetSeconds: 28800,
          );
          final task = memory.store.createNotesTaskFromMessage(
            messageId: 'notes-source',
            expectedSourceRev: 1,
            itemNo: 0,
            roomMode: 'full',
            hostKey: hostKey,
            hostSessionId: _session,
            agreement: notesAgreement(),
          );
          id = task['task_id']! as String;
          create =
              memory.store.prepareHostTaskOperation(
                    taskId: id,
                    taskRev: 1,
                    hostKey: hostKey,
                    hostStoreId: 'original-store',
                    initialOpportunity: true,
                  )!['request']!
                  as MemoryRow;
          hostSnapshot('E1', 1);
        },
      );
      try {
        unawaited(
          Navigator.of(tester.element(find.byType(CompanionPage))).push(
            MaterialPageRoute<void>(
              builder: (_) => CompanionTasksPage(memory: room.memory, taskId: id),
            ),
          ),
        );
        await tester.pump();
        await settleMixed(
          tester,
          room.memory.hostTasks.run(room.memory.store.hostTask(id)!, client: client, hostKey: hostKey),
        );
        await flush(tester);
        await settleMixed(tester, client.notesWatched.future);
        client.notesEvents.add(
          parseFollowFrame(_notesAgent, {
            'type': 'snapshot',
            'cursor': -1,
            'records': [],
            'assistantStream': {'revision': 0},
          }),
        );
        engineApproval('E1');
        await flush(tester);
        await tester.pump(CompanionAsk.detailWait);
        await tester.pumpAndSettle();
        final target = tester.widget<CompanionAsk>(find.byType(CompanionAsk)).approvalTarget!;
        final old = tester.widget<ApprovalCard>(find.byType(ApprovalCard));
        expect(old.request.sessionId, _notesAgent);
        expect(old.request.eventId, 'gateway-E1');
        expect(find.text('让电脑接着做'), findsNothing);
        expect(target.callId, 'call-E1');
        expect(room.memory.store.hostTask(id)!['source_session_id'], 'full:$hostKey');
        expect(room.memory.store.hostTask(id)!['host_session_id'], _session);
        expect((room.memory.store.hostTask(id)!['snapshot']! as Map)['approval'], approval('E1'));

        client.notesEvents.add(HostEvent.fromFrame({'type': 'cancel', 'eventId': 'gateway-E1'}));
        engineApproval('E2');
        await flush(tester);
        expect(room.container.read(chatProvider(_notesAgent)).openApproval?.eventId, 'gateway-E2');
        await settleMixed(tester, old.onRespond(old.request, ApprovalDecision.allowOnce));
        await settleMixed(tester, old.onAllowAll!(old.request));
        expect(bridge.results, isEmpty);
        // The task still points to E1; an E2 in the Agent does not substitute
        // for that binding until an actual complete Host snapshot says so.
        await tester.pumpAndSettle();
        expect(find.byType(ApprovalCard), findsNothing);

        hostSnapshot('E2', 2);
        await tester.tap(find.byTooltip('刷新'));
        await settleMixed(
          tester,
          room.memory.hostTasks.run(room.memory.store.hostTask(id)!, client: client, hostKey: hostKey),
        );
        await flush(tester);
        // A fresh watch of the task Agent may begin while the original card
        // is revalidated. Deliver its real current event, not a Page override.
        client.notesEvents.add(
          parseFollowFrame(_notesAgent, {
            'type': 'snapshot',
            'cursor': -1,
            'records': [],
            'assistantStream': {'revision': 0},
          }),
        );
        engineApproval('E2');
        await flush(tester);
        await tester.pump(CompanionAsk.detailWait);
        await tester.pumpAndSettle();
        final current = tester.widget<ApprovalCard>(find.byType(ApprovalCard));
        expect(current.request.eventId, 'gateway-E2');
        if (outcome == 'cancel') {
          room.memory.store.submitMessage(
            id: 'cancel-notes',
            sessionId: 'full:$hostKey',
            text: '取消这次笔记整理',
            saidAtUtc: _now + 1,
            offsetMinutes: 480,
          );
          room.memory.store.cancelNotesTask(
            taskId: id,
            expectedTaskRev: 1,
            messageId: 'cancel-notes',
            expectedSourceRev: 1,
            itemNo: 0,
          );
          room.memory.changed();
          // Invoke the already captured callback before the next frame; the
          // production revision closure must gate it even while E2 is pending.
          await settleMixed(tester, current.onRespond(current.request, ApprovalDecision.allowOnce));
          await settleMixed(tester, current.onAllowAll!(current.request));
          expect(bridge.results, isEmpty);
          expect(room.memory.store.hostTask(id)!['task_rev'], 2);
        } else if (outcome == 'missing') {
          // A legal 404 response is an HTTP/UI evidence boundary. The frozen
          // Host has no task deletion route; this is not a claim that it lost
          // a durable task or that deletion was exercised here.
          final target = tester.widget<CompanionAsk>(find.byType(CompanionAsk)).approvalTarget!;
          bridge.taskMissing = true;
          await tester.tap(find.byTooltip('刷新'));
          await settleMixed(
            tester,
            room.memory.hostTasks.run(room.memory.store.hostTask(id)!, client: client, hostKey: hostKey),
          );
          await tester.pumpAndSettle();
          expect(target.isCurrent(), isFalse);
          expect(find.byType(ApprovalCard), findsNothing);
          expect(bridge.results, isEmpty);
          expect(room.memory.store.hostTask(id)!['state'], 'waiting');
          expect(room.memory.store.hostTask(id)!['applied_host_receipt_seq'], 2);
          expect((room.memory.store.hostTask(id)!['snapshot']! as Map)['approval'], approval('E2'));
        } else {
          await tester.ensureVisible(
            find.descendant(of: find.byType(ApprovalCard), matching: find.byType(FilledButton)),
          );
          await tester.tap(find.descendant(of: find.byType(ApprovalCard), matching: find.byType(FilledButton)));
          await settleMixed(tester, bridge.responded.future);
          await flush(tester);
          expect((bridge.results.single['payload']! as Map)['args'], {
            'clientId': 'approval-peer',
            'eventId': 'gateway-E2',
            'outcome': {'kind': 'result', 'value': ApprovalDecision.allowOnce.wire},
          });
          expect(room.memory.store.hostTask(id)!['state'], 'waiting');
          expect(room.memory.store.hostTask(id)!['applied_host_receipt_seq'], 2);
          expect(room.memory.store.taskReceipts(id), isEmpty);
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await settleMixed(tester, client.notesEvents.close());
        unawaited(client.events.close());
        await settleMixed(tester, client.mux.connection.close());
        await settleMixed(tester, client.close());
      }
    });
  }

  // A1: the room has no chat approvals any more; a Host task Agent's approval
  // is answered on the tasks page, through the same CompanionAsk. These keep
  // the old approval contracts on that surface.
  for (final allowAll in [false, true]) {
    testWidgets('D tasks page keeps E1 callbacks from answering E2 and preserves allowAll=$allowAll', (tester) async {
      final notes = await _NotesApproval.open(tester, temporary);
      try {
        notes.engineApproval('E1');
        await flush(tester);
        await tester.pump(CompanionAsk.detailWait);
        await tester.pumpAndSettle();
        final oldCard = tester.widget<ApprovalCard>(find.byType(ApprovalCard));
        final oldTarget = tester.widget<CompanionAsk>(find.byType(CompanionAsk)).approvalTarget!;
        expect(oldTarget.eventId, 'gateway-E1');
        expect(oldTarget.callId, 'call-E1');
        expect(oldTarget.isCurrent(), isTrue);

        notes.client.notesEvents.add(HostEvent.fromFrame({'type': 'cancel', 'eventId': 'gateway-E1'}));
        notes.engineApproval('E2');
        await flush(tester);
        expect(notes.chat.openApproval?.eventId, 'gateway-E2');
        // An outgoing card can still own a captured button. Recheck the real
        // pending event before calling either original action.
        await settleMixed(tester, oldCard.onRespond(oldCard.request, ApprovalDecision.allowOnce));
        await settleMixed(tester, oldCard.onAllowAll!(oldCard.request));
        expect(notes.bridge.results, isEmpty);
        expect(notes.chat.autoApprove, isFalse);

        await notes.hostMoves('E2', 2);
        final currentCard = tester.widget<ApprovalCard>(find.byType(ApprovalCard));
        expect(currentCard.request.eventId, 'gateway-E2');
        expect(currentCard.request.callId, 'call-E2');
        if (allowAll) {
          await tester.ensureVisible(find.widgetWithText(TextButton, '本对话都允许'));
          await tester.tap(find.widgetWithText(TextButton, '本对话都允许'));
          await flush(tester);
          await tester.pumpAndSettle();
          expect(find.text('本对话都允许？'), findsOneWidget);
          await tester.tap(find.widgetWithText(FilledButton, '全部允许'));
        } else {
          await tester.ensureVisible(
            find.descendant(of: find.byType(ApprovalCard), matching: find.byType(FilledButton)),
          );
          await tester.tap(find.descendant(of: find.byType(ApprovalCard), matching: find.byType(FilledButton)));
        }
        await settleMixed(tester, notes.bridge.responded.future);
        await flush(tester);
        final envelope = notes.bridge.results.single;
        expect(envelope['method'], r'$events/result');
        expect((envelope['payload']! as Map)['args'], {
          'clientId': 'approval-peer',
          'eventId': 'gateway-E2',
          'outcome': {'kind': 'result', 'value': ApprovalDecision.allowOnce.wire},
        });
        expect(notes.chat.autoApprove, allowAll);
        expect(notes.chat.error, isNull);
      } finally {
        await notes.close(tester);
      }
    });
  }

  testWidgets('an approval waits for the command it is about before it can be allowed', (tester) async {
    final notes = await _NotesApproval.open(tester, temporary);
    try {
      final wire = _Wire(_notesAgent, notes.client.notesEvents.add)
        ..beginTurn()
        ..start('early-approval');
      wire.text('我看一下。');
      await flush(tester);
      // The approval arrives before its tool call has reached the transcript.
      notes.engineApproval('E1', toolName: 'bash');
      await flush(tester);
      expect(notes.chat.openApproval?.eventId, 'gateway-E1');
      expect(find.byType(ApprovalCard), findsNothing);
      // Its command comes in: now there is something to allow.
      wire.endText();
      const call = {'type': 'tool-call', 'id': 'call-E1', 'name': 'bash', 'arguments': '{"command":"ls"}'};
      wire.chunk({'type': 'block-start', 'index': 1, 'blockType': 'tool-call'});
      wire.chunk({
        'type': 'tool-call-delta',
        'index': 1,
        'id': 'call-E1',
        'name': 'bash',
        'argumentsDelta': '{"command":"ls"}',
      });
      wire.chunk({'type': 'block-end', 'index': 1, 'block': call});
      wire.finish('tool-calls');
      wire.settle('assistant/message', text: '我看一下。', extraParts: [call]);
      wire.log('tool/call', {
        'turn': 1,
        'step': 1,
        'callId': 'call-E1',
        'name': 'bash',
        'arguments': '{"command":"ls"}',
      });
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(ApprovalCard), findsOneWidget);
      expect(find.textContaining('ls'), findsWidgets);
    } finally {
      await notes.close(tester);
    }
  });

  testWidgets('an approval waits while its arguments are still arriving', (tester) async {
    final notes = await _NotesApproval.open(tester, temporary);
    try {
      final wire = _Wire(_notesAgent, notes.client.notesEvents.add)
        ..beginTurn()
        ..start('streaming-args');
      wire.text('我看一下。');
      wire.endText();
      wire.chunk({'type': 'block-start', 'index': 1, 'blockType': 'tool-call'});
      wire.chunk({
        'type': 'tool-call-delta',
        'index': 1,
        'id': 'call-E1',
        'name': 'bash',
        'argumentsDelta': '{"command":"rm -',
      });
      await flush(tester);
      notes.engineApproval('E1', toolName: 'bash');
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 600));
      // Its call is there, its command half written: nothing to allow yet.
      expect(notes.chat.items.whereType<ToolChatItem>().single.status, ToolStatus.streaming);
      expect(find.byType(ApprovalCard), findsNothing);
    } finally {
      await notes.close(tester);
    }
  });

  testWidgets('an approval whose call never shows up is shown after a short wait, as the main chat does', (
    tester,
  ) async {
    final notes = await _NotesApproval.open(tester, temporary);
    try {
      _Wire(_notesAgent, notes.client.notesEvents.add)
        ..beginTurn()
        ..start('lonely-approval');
      await flush(tester);
      notes.engineApproval('E1');
      await flush(tester);
      expect(find.byType(ApprovalCard), findsNothing);
      await tester.pump(CompanionAsk.detailWait);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(ApprovalCard), findsOneWidget);
    } finally {
      await notes.close(tester);
    }
  });

  // A1: one user turn, two model requests joined by a real tool round on the
  // phone. (The old in-room approval attention has no room surface now.)
  testWidgets('positive control: two assistant messages with a tool round keep one accumulated reply', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      await room.send('帮我查一下。');
      const first = '[表情:开心]我看一下。';
      room.words(first);
      room.toolCall(1, 'call-positive', 'recall', {'query': '琴'});
      await flush(tester);
      expect(room.speech(tester), '我看一下。');
      await room.end(stop: 'tool_use');
      await room.chatRequest(2);
      final results = (((room.chats.last['messages']! as List).last as Map)['content']! as List).cast<Map>();
      expect(results.single['tool_use_id'], 'call-positive');
      expect(jsonDecode(results.single['content']! as String), containsPair('applied', true));
      const second = '[动作:点头]查好了。';
      room.words(second);
      await flush(tester);
      await room.end();
      expect(room.running, isFalse);
      expect(room.memory.store.messages().where((row) => row['role'] == 'user'), hasLength(1));
      expect(room.memory.store.messages().where((row) => row['role'] == 'assistant').map((row) => row['text']), [
        first,
        second,
      ]);
      expect(room.speech(tester), '我看一下。\n查好了。');
      expect(room.emotionNames, ['happy']);
      expect(room.actionNames, ['nod']);
    } finally {
      await room.close(tester);
    }
  });

  // A1: the phone loop does not retry a provider failure by itself. A request
  // that failed before any words keeps its source; the explicit resend of the
  // same line is answered by the replacement, its markers played once.
  for (final replacement in [
    (name: 'emotion and words', after: '[表情:担心]改句。', words: '改句。', emotion: 'worried'),
    (name: 'marker only change', after: '[表情:开心]好。', words: '好。', emotion: 'happy'),
  ]) {
    testWidgets('an explicit resend after a wordless failure replaces it: ${replacement.name}', (tester) async {
      final room = _Room(temporary);
      await room.open(tester);
      try {
        await room.send('说一句话。');
        await room.drop();
        expect(room.speech(tester), '这句话没送出去，要不要再说一次？');
        expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '说一句话。');
        await tester.tap(find.byKey(const ValueKey('send')));
        await room.chatRequest(2);
        room.words(replacement.after);
        await flush(tester);
        expect(room.speech(tester), replacement.words);
        await room.end();
        expect(room.speech(tester), replacement.words);
        expect(room.emotionNames, ['worried', replacement.emotion]);
        expect(room.memory.store.messages().where((row) => row['role'] == 'user'), hasLength(1));
        expect(
          room.memory.store.messages().where((row) => row['role'] == 'assistant').single['text'],
          replacement.after,
        );
      } finally {
        await room.close(tester);
      }
    });
  }

  // A1 desired contract, skipped on a product bug: a reply that broke off
  // after some words, with no tool dispatched, is closed to retry
  // (companion_agent_visit.dart:424-430 shows companionAgentRetryClosed), and
  // because retrySource still holds that source, sending the identical line
  // again is refused the same way (companion_agent_visit.dart:292-301) instead
  // of getting a fresh reply. The old engine retried such a draft in place.
  testWidgets('buffered failed draft to a resent replacement plays the identical action once per reply', (
    tester,
  ) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      await room.send('说一句话。');
      const text = '[动作:点头]好。';
      room.words(text);
      await flush(tester);
      await room.drop();
      await tester.enterText(find.byType(TextField), '说一句话。');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      await room.chatRequest(2);
      room.words(text);
      await room.end();
      expect(room.speech(tester), '好。');
      expect(room.actionNames, ['nod', 'nod']);
      room.container.read(companionAgentProvider).changed();
      await flush(tester);
      expect(room.actionNames, ['nod', 'nod']);
    } finally {
      await room.close(tester);
    }
  });

  // A1: after a real tool round the turn is closed to retry, which is where
  // companionAgentRetryClosed belongs. The committed prefix and its marker stay.
  testWidgets('a failure after a tool round keeps the committed prefix and its markers', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      await room.send('帮我查一下。');
      const prefix = '[动作:挥手]前面。';
      room.words(prefix);
      room.toolCall(1, 'prefix-call', 'recall', {'query': '琴'});
      await room.end(stop: 'tool_use');
      await room.chatRequest(2);
      expect(room.speech(tester), '前面。');
      room.words('[表情:难过]这是一段没有成功的很长后半句。');
      await flush(tester);
      await room.drop();
      expect(room.running, isFalse);
      expect(room.speech(tester), L10n.of(tester.element(find.byType(CompanionPage))).companionAgentRetryClosed);
      expect(room.memory.store.messages().where((row) => row['role'] == 'assistant').first['text'], prefix);
      expect(room.actionNames, ['wave']);
      expect(room.emotionNames, ['sad', 'worried']);
      expect(room.chats, hasLength(2), reason: 'nothing is sent again by itself');
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('finish makes a draft nonstreaming before normal durable handoff without replay', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      await room.send('说一句话。');
      const text = '[动作:点头]你好。';
      room.words(text);
      await flush(tester);
      expect(room.running, isTrue);
      expect(room.memory.store.messages().where((row) => row['role'] == 'assistant'), isEmpty);
      await room.end();
      expect(room.running, isFalse);
      expect(room.memory.store.messages().where((row) => row['role'] == 'assistant').single['text'], text);
      expect(room.speech(tester), '你好。');
      expect(room.actionNames, ['nod']);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('a split marker remains hidden until complete and does not replay on commit', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      await room.send('说一句话。');
      room.words('[表情:担');
      await flush(tester);
      expect(room.emotionNames, isEmpty);
      room.words('心]好。');
      await flush(tester);
      expect(room.speech(tester), '好。');
      expect(room.emotionNames, ['worried']);
      await room.end();
      expect(room.emotionNames, ['worried']);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('a new user can receive the same words after the old subtitle expired', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      const text = '[动作:点头]好。';
      await room.send('说一句话。');
      room.words(text);
      await room.end();
      await tester.pump(const Duration(seconds: 10));
      expect(room.speech(tester), isNull);
      await room.send('再说一句。');
      room.words(text);
      await room.end();
      expect(room.memory.store.messages().where((row) => row['role'] == 'user'), hasLength(2));
      expect(room.speech(tester), '好。');
      expect(room.actionNames, ['nod', 'nod']);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('an unfinished literal marker revealed at turn end stays stable on duplicate notices', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      await room.send('说一句话。');
      const text = '文字[表情:';
      room.words(text);
      await flush(tester);
      expect(room.speech(tester), '文字');
      await room.end();
      expect(room.speech(tester), text);
      final says = room.commands.where((c) => c.$1 == 'say').length;
      for (var i = 0; i < 3; i++) {
        room.container.read(companionAgentProvider).changed();
        await flush(tester);
      }
      expect(room.speech(tester), text);
      expect(room.commands.where((c) => c.$1 == 'say').length, says);
      expect(room.emotionNames, isEmpty);
    } finally {
      await room.close(tester);
    }
  });

  // A1 desired contract, skipped on the same product bug as above
  // (companion_agent_visit.dart:424-430 and :292-301): a draft that broke off
  // without any tool cannot be answered again, so the shorter successful
  // reply never replaces the failed subtitle and marker.
  testWidgets('desired contract: successful shorter retry replaces failed attempt subtitle and marker', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      await room.send('说一句话。');
      const oldText = '这是第一次尝试流出的很长一句话，还没有完成。';
      room.words('[表情:开心]$oldText');
      await flush(tester);
      expect(room.speech(tester), oldText);
      expect(room.emotionNames, ['happy']);
      await room.drop();
      await tester.enterText(find.byType(TextField), '说一句话。');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      await room.chatRequest(2);
      room.words('[表情:担心]好。');
      await room.end();
      expect(room.memory.store.messages().where((row) => row['role'] == 'user'), hasLength(1));
      expect(room.speech(tester), '好。');
      expect(room.emotionNames, ['happy', 'worried', 'worried']);
    } finally {
      await room.close(tester);
    }
  });
}

/// The tasks page over a full room, showing one notes task whose Host Agent
/// waits on an approval: the real CompanionAsk and ChatController path.
class _NotesApproval {
  _NotesApproval._(this.room, this.bridge, this.client, this.id, this.create);
  final _Room room;
  final _NotesApprovalBridge bridge;
  final _NotesApprovalClient client;
  final String id;
  final MemoryRow create;

  ChatState get chat => room.container.read(chatProvider(_notesAgent));

  static MemoryRow approval(String event) => {
    'taskRev': 1,
    'stepKey': 'model',
    'agentId': _notesAgent,
    'approvalId': 'engine-approval-$event',
    'eventId': 'gateway-$event',
    'callId': 'call-$event',
  };

  void hostSnapshot(String event, int seq) {
    bridge.taskSnapshot = {
      ...notesSnapshot(
        create,
        state: 'waiting',
        seq: seq,
        approval: approval(event),
        steps: [
          {
            'taskRev': 1,
            'stepKey': 'model',
            'attemptId': 'model-wait',
            'state': 'waiting',
            'startedAtMs': _now,
            'finishedAtMs': null,
            'reason': 'approval_required',
            'result': null,
          },
        ],
      ),
      'waitReason': 'approval_required',
    };
  }

  void engineApproval(String event, {String toolName = 'web_fetch'}) => client.notesEvents.add(
    HostEvent.fromFrame({
      'type': 'waterfall',
      'event': 'approval/request',
      'eventId': 'gateway-$event',
      'agentId': _notesAgent,
      'request': {'toolName': toolName, 'callId': 'call-$event'},
    }),
  );

  /// The Host's complete task snapshot names [event]; the page refreshes and
  /// the Agent's actual current event arrives on a fresh watch.
  Future<void> hostMoves(String event, int seq) async {
    final tester = room.tester;
    hostSnapshot(event, seq);
    await tester.tap(find.byTooltip('刷新'));
    await settleMixed(
      tester,
      room.memory.hostTasks.run(room.memory.store.hostTask(id)!, client: client, hostKey: _hostKey),
    );
    await flush(tester);
    client.notesEvents.add(
      parseFollowFrame(_notesAgent, {
        'type': 'snapshot',
        'cursor': -1,
        'records': [],
        'assistantStream': {'revision': 0},
      }),
    );
    engineApproval(event);
    await flush(tester);
    await tester.pump(CompanionAsk.detailWait);
    await tester.pumpAndSettle();
  }

  static final _hostKey = '${HostRef.local.kind.name}:${HostRef.local.id}';

  static Future<_NotesApproval> open(WidgetTester tester, Directory temporary) async {
    final bridge = _NotesApprovalBridge();
    final client = _NotesApprovalClient(bridge);
    final room = _Room(temporary, client: client);
    late String id;
    late MemoryRow create;
    await room.open(
      tester,
      seed: (memory) {
        memory.store.submitMessage(
          id: 'notes-source',
          sessionId: 'full:$_hostKey',
          text: '请电脑把2026-11-21的笔记整理成一页待办，原件别动',
          saidAtUtc: _now,
          offsetMinutes: 480,
          zoneId: 'Asia/Shanghai',
          offsetSeconds: 28800,
        );
        final task = memory.store.createNotesTaskFromMessage(
          messageId: 'notes-source',
          expectedSourceRev: 1,
          itemNo: 0,
          roomMode: 'full',
          hostKey: _hostKey,
          hostSessionId: _session,
          agreement: notesAgreement(),
        );
        id = task['task_id']! as String;
        create =
            memory.store.prepareHostTaskOperation(
                  taskId: id,
                  taskRev: 1,
                  hostKey: _hostKey,
                  hostStoreId: 'original-store',
                  initialOpportunity: true,
                )!['request']!
                as MemoryRow;
      },
    );
    final notes = _NotesApproval._(room, bridge, client, id, create)..hostSnapshot('E1', 1);
    unawaited(
      Navigator.of(tester.element(find.byType(CompanionPage))).push(
        MaterialPageRoute<void>(
          builder: (_) => CompanionTasksPage(memory: room.memory, taskId: id),
        ),
      ),
    );
    await tester.pump();
    await settleMixed(
      tester,
      room.memory.hostTasks.run(room.memory.store.hostTask(id)!, client: client, hostKey: _hostKey),
    );
    await flush(tester);
    await settleMixed(tester, client.notesWatched.future);
    client.notesEvents.add(
      parseFollowFrame(_notesAgent, {
        'type': 'snapshot',
        'cursor': -1,
        'records': [],
        'assistantStream': {'revision': 0},
      }),
    );
    await flush(tester);
    return notes;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await settleMixed(tester, client.notesEvents.close());
    unawaited(client.events.close());
    await settleMixed(tester, client.mux.connection.close());
    await settleMixed(tester, client.close());
  }
}
