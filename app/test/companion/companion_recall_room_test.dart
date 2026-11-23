// Phone-owned memory and recall cleanup through the real Page, in full mode.
// Bridge responses, Session creation and the model's HTTP answer (relayed by a
// test Host, ADD67) are doubles; the phone tool loop, its Host reader and
// receipt journal are production code.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/companion_notes_peer.dart' show NotesPeer, hostAgentPath;
import 'companion_test_settle.dart';

const _store = '33333333-3333-4333-8333-333333333333';
const _epoch = '44444444-4444-4444-8444-444444444444';
const _binding = '22222222-2222-4222-8222-222222222222';

class _Bridge extends DshConnection {
  _Bridge() : super(Uri.parse('http://127.0.0.1:9'));
  String instance = 'first-instance';
  final phoneSessions = <String>{};
  String? rejectPrepare;
  bool failRevoke = false;
  bool chatUsage = false;
  bool phoneMemory = true;
  final prepared = <Map<String, Object?>>[];
  final revokes = <Map<String, Object?>>[];
  final binds = <Map<String, Object?>>[];

  /// The full room's model route (ADD67): the room asks this Host, which
  /// relays to the scripted model below.
  NotesPeer? host;

  DshHttpResponse json(Object value, {int status = 200}) =>
      DshHttpResponse(status, 'application/json', Uint8List.fromList(utf8.encode(jsonEncode(value))));

  Map<String, Object?> capability(String session) => {
    'v': 1,
    'supported': true,
    'instanceId': instance,
    'sessionId': session,
    'profileRevision': 0,
    'profileAccepted': true,
    'phoneMemory': phoneMemory,
    'chatUsage': chatUsage,
    'memoryMode': phoneSessions.contains(session) ? 'phone' : 'query',
  };

  void restart() {
    instance = 'restarted-instance';
    phoneSessions.clear();
  }

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
      return host!.connection.get(
        path,
        query: query,
        headers: headers,
        timeout: timeout,
        followRedirects: followRedirects,
        maxResponseBytes: maxResponseBytes,
      );
    }
    if (path.endsWith('/memories')) {
      return json({'v': 1, 'storeId': _store, 'revision': 0, 'memoryRevision': 0, 'memories': []});
    }
    if (path.endsWith('/prompt-context')) return json(capability(query!['sessionId']!));
    if (path.endsWith('/usage')) {
      return json({
        'v': 1,
        'instanceId': instance,
        'sessionId': query!['sessionId'],
        'requestId': query['requestId'],
        'binding': null,
        'state': 'unknown',
        'complete': false,
        'revision': 0,
        'gaps': ['missing-root'],
        'observedAdapterCalls': 0,
        'activeCalls': 0,
        'physicalRequests': null,
        'receipts': [],
      });
    }
    return json({
      'storeId': _store,
      'revision': 0,
      'memoryRevision': 0,
      'asOf': 1793937600000,
      'state': {'valence': 0.25, 'energy': 0.75, 'closeness': 0, 'activity': 'idle'},
    });
  }

  @override
  Future<DshHttpStreamResponse> postJsonStream(
    String path,
    Object? body, {
    required DshHttpAbort abort,
    Duration? headerTimeout,
    Duration? idleTimeout = const Duration(seconds: 20),
  }) => host!.connection.postJsonStream(
    path,
    body,
    abort: abort,
    headerTimeout: headerTimeout,
    idleTimeout: idleTimeout,
  );

  @override
  Future<DshHttpResponse> postJson(String path, Object? body, {Duration? timeout}) async {
    if (path.endsWith('/prompt-context')) {
      final update = Map<String, Object?>.from(body! as Map);
      prepared.add(update);
      final code = rejectPrepare;
      rejectPrepare = null;
      if (code != null) {
        return json({
          'error': {'code': code, 'message': 'scripted preparation rejection'},
        }, status: 409);
      }
      if (update.containsKey('phoneMemory')) phoneSessions.add(update['sessionId']! as String);
      return json(capability(update['sessionId']! as String));
    }
    return get(path);
  }

  @override
  Future<DshHttpResponse> getBounded(
    String path, {
    Map<String, String>? query,
    required int maxBytes,
    bool autoUncompress = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (path.endsWith('/recall')) {
      return json({
        'v': 1,
        'supported': true,
        'reason': null,
        'busy': false,
        'activeBindingId': null,
        'selectorVersion': companionRecallSelector,
        'maxItems': 12,
        'textUtf16Budget': 1200,
      });
    }
    return json({
      'error': {'code': 'companion/not-found'},
    }, status: 404);
  }

  @override
  Future<DshHttpResponse> postBytes(
    String path,
    List<int> bytes, {
    Map<String, String>? query,
    String contentType = 'application/octet-stream',
    Duration? timeout,
    bool followRedirects = true,
    int? maxResponseBytes,
    DshHttpAbort? abort,
  }) async {
    final body = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    if (path.endsWith('/bind')) binds.add(body);
    if (path.endsWith('/revoke')) {
      revokes.add(body);
      if (failRevoke) {
        return json({
          'error': {'code': 'companion/unavailable'},
        }, status: 503);
      }
      return json({
        'v': 1,
        'bindingId': body['bindingId'],
        'bridgeEpoch': _epoch,
        'recallEpoch': 1,
        'storeId': _store,
        'memoryRevision': 0,
        'sessionId': 'old',
        'status': 'retired',
        'reason': 'revoked',
        'selectorVersion': companionRecallSelector,
        'serverNow': 1794090000000,
      });
    }
    return json({
      'error': {'code': 'companion/not-found'},
    }, status: 404);
  }
}

class _Mux extends DshMux {
  _Mux(super.carrier);
  final connection = StreamController<DshConnectionState>.broadcast();
  @override
  Stream<DshConnectionState> get states => connection.stream;
}

class _Client extends DshClient {
  _Client(super.connection);
  late final _fakeMux = _Mux(carrier);
  final _watches = <StreamController<DshEvent>>[];
  final _bySession = <String, List<StreamController<DshEvent>>>{};
  final records = <String, List<Map<String, Object?>>>{};
  final prompts = <({String session, String text, String requestId})>[];
  void Function(String, String)? beforePrompt;
  @override
  _Mux get mux => _fakeMux;

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) {
    final controller = StreamController<DshEvent>();
    _watches.add(controller);
    _bySession.putIfAbsent(sessionId, () => []).add(controller);
    controller.onListen = () => controller.add(
      parseFollowFrame(sessionId, {
        'type': 'snapshot',
        'cursor': (records[sessionId]?.length ?? 0) - 1,
        'records': records[sessionId] ?? [],
        'assistantStream': {'revision': 0},
      }),
    );
    return controller.stream;
  }

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    List<PromptImage> images = const [],
    List<String> fileReceiptIds = const [],
    String? requestId,
    PromptMode mode = PromptMode.queue,
    String? timeZone,
  }) async {
    final id = requestId!;
    beforePrompt?.call(sessionId, id);
    prompts.add((session: sessionId, text: text, requestId: id));
    final log = records.putIfAbsent(sessionId, () => []);
    final entry = <String, Object?>{
      'type': 'user/message',
      'seq': log.length,
      'time': 1795260000123 + log.length,
      'data': {
        'id': 'message-${log.length}',
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
        ],
        'source': {'kind': 'user', 'rpcId': id},
      },
    };
    log.add(entry);
    for (final watch in _bySession[sessionId] ?? <StreamController<DshEvent>>[]) {
      watch.add(parseFollowFrame(sessionId, {'type': 'event', 'event': entry}));
    }
    return id;
  }

  Future<void> closeAll() async {
    for (final watch in _watches) {
      await watch.close();
    }
    await _fakeMux.connection.close();
    await close();
  }
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true, apiKey: 'synthetic-test-key');
}

String _reply(String text) => [
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'text_delta', 'text': text},
  },
  {
    'type': 'message_delta',
    'delta': {'stop_reason': 'end_turn'},
    'usage': {'input_tokens': 50, 'output_tokens': 5},
  },
  {'type': 'message_stop'},
].map((event) => 'data: ${jsonEncode(event)}\n\n').join();

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

class _Sessions extends CompanionSessions {
  int created = 0;
  int forgotten = 0;
  String get key => 'local:${HostRef.local.id}';
  @override
  Map<String, CompanionBinding> build() => const {};
  @override
  Future<CompanionBinding> ensure({String? memoryArchiveId, int? memoryControlRevision}) async {
    final known = of(HostRef.local);
    if (known != null &&
        known.memoryArchiveId == memoryArchiveId &&
        known.memoryControlRevision == memoryControlRevision) {
      return known;
    }
    final binding = CompanionBinding(
      'fresh-${++created}',
      memoryArchiveId: memoryArchiveId,
      memoryControlRevision: memoryControlRevision,
    );
    state = {...state, key: binding};
    return binding;
  }

  @override
  Future<void> forget() async {
    forgotten++;
    state = {};
  }

  @override
  Future<void> forgetAll() async {
    state = {};
  }
}

class _Room {
  _Room(this.root);
  final Directory root;
  final bridge = _Bridge();
  late final client = _Client(bridge);
  final sessions = _Sessions();
  late CompanionMemoryOwner memory;
  CompanionStageEvents? events;

  /// The room's chat model, asked through the Host in full mode (ADD67).
  final asked = <Map<String, Object?>>[];
  String reply = '嗯，我在。';

  /// An HTTP status for the next model request, or 'network'.
  String? failNext;
  void Function(Map<String, Object?>)? beforeModel;

  /// The user's text in the last model request.
  String lastAsked() {
    final last = (asked.last['messages']! as List).last as Map;
    final content = last['content'];
    return content is String ? content : jsonEncode(content);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  http.Client model() => MockClient.streaming((request, body) async {
    final sent = jsonDecode(await body.bytesToString()) as Map<String, Object?>;
    asked.add(sent);
    beforeModel?.call(sent);
    final failure = failNext;
    failNext = null;
    if (failure == 'network') throw http.ClientException('fixture offline');
    if (failure != null) return http.StreamedResponse(Stream.value(utf8.encode('{}')), int.parse(failure));
    return http.StreamedResponse(
      Stream.value(utf8.encode(_reply(reply))),
      200,
      headers: {'content-type': 'text/event-stream; charset=utf-8'},
    );
  });

  Future<void> open(WidgetTester tester) async {
    // A valid old Host has the text route but no agent turn.
    bridge.host = (await tester.runAsync(NotesPeer.open))!;
    bridge.host!.hostModel
      ..model = model
      ..agent = bridge.phoneMemory;
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    Directory('${root.path}/pack/runtime').createSync(recursive: true);
    Directory('${root.path}/pack/character').createSync(recursive: true);
    File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
    File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeHostProvider.overrideWith(_Host.new),
          activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: true))),
          companionSessionsProvider.overrideWith(() => sessions),
          settingsProvider.overrideWith(_Settings.new),
          companionLightClientProvider.overrideWithValue(model),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('zh'),
          home: CompanionPage(
            storeOverride: CompanionPackStore(root),
            stageController: CompanionStageController(sink: (_, _) {}),
            stageBuilder: (_, next) {
              events = next;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    for (var i = 0; i < 100 && events == null; i++) {
      await settle(tester);
    }
    expect(events, isNotNull);
    final container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
    memory = await settleMixed(tester, container.read(companionMemoryOwnerProvider(root.absolute.path).future));
    events!.onReady();
    await settle(tester);
    await tester.pump(const Duration(seconds: 8));
    await settle(tester);
  }

  Future<void> say(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send).last);
    for (var i = 0; i < 3; i++) {
      await settle(tester);
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    await settleMixed(tester, client.closeAll());
    await tester.runAsync(bridge.host!.close);
  }
}

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('companion-phone-room');
    SharedPreferences.setMockInitialValues({
      'companion_mode': 'full',
      'companion_touch_hint_done': true,
      'companion_home_hint_done': true,
    });
  });
  tearDown(() {
    root.deleteSync(recursive: true);
  });

  // A1: full mode no longer prepares Host prompt context or calls the Host
  // prompt RPC; phone memory goes into the phone model request itself. These
  // keep the old intents on that path: a failed first request keeps the
  // durable source for an explicit resend, nothing retries by itself, and the
  // usage owner is recorded before anything leaves the phone.
  for (final failure in ['500', 'network']) {
    testWidgets('a $failure failure keeps the source and waits for an explicit resend of the same line', (
      tester,
    ) async {
      final room = _Room(root);
      await room.open(tester);
      try {
        await room.say(tester, '第一句');
        expect(room.asked, hasLength(1));
        expect(find.text('嗯，我在。'), findsOneWidget);
        room.failNext = failure;
        const raw = '  重启后这句话\n';
        await room.say(tester, raw);
        expect(room.asked, hasLength(2));
        expect(room.lastAsked(), contains(raw.trim()));
        expect(find.text('这句话没送出去，要不要再说一次？'), findsOneWidget);
        expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, raw);
        final saved = Map<String, Object?>.from(room.memory.store.messages().last);
        expect(saved['text'], raw);
        await tester.pump(const Duration(seconds: 30));
        await room.settle(tester);
        expect(room.asked, hasLength(2), reason: 'a failed request is not sent again by itself');
        await room.say(tester, raw);
        expect(room.asked, hasLength(3));
        expect(room.lastAsked(), contains(raw.trim()));
        final users = room.memory.store.messages().where((row) => row['role'] == 'user').toList();
        expect(users, hasLength(2));
        expect(users.last['id'], saved['id']);
        expect(users.last['first_seq'], saved['first_seq']);
        expect(room.client.prompts, isEmpty);
        expect(room.bridge.prepared, isEmpty);
      } finally {
        await room.close(tester);
      }
    });
  }

  testWidgets('a busy model answer keeps the source and does not silently retry', (tester) async {
    final room = _Room(root)..failNext = '429';
    await room.open(tester);
    try {
      await room.say(tester, '现况这句');
      expect(find.text('那边有点忙，等一下再和我说吧。'), findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      await room.settle(tester);
      expect(room.asked, hasLength(1));
      expect(room.sessions.forgotten, 0);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '现况这句');
      expect(room.memory.store.messages().single['text'], '现况这句');
      expect(room.client.prompts, isEmpty);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('the phone loop persists its usage receipt before the model request leaves', (tester) async {
    final room = _Room(root)..bridge.chatUsage = true;
    await room.open(tester);
    var observed = false;
    room.beforeModel = (sent) {
      final receipt = room.memory.store.requests().single;
      expect(receipt['category'], 'chat');
      expect(receipt['provider'], 'deepseek');
      expect(receipt['model'], 'deepseek-flash');
      expect(sent['model'], receipt['model']);
      // Through the Host (ADD67) the phone records the handoff before its POST;
      // the Host's own dispatch receipt then marks it sent.
      expect(receipt['uncertain_at_ms'], isNotNull);
      expect(receipt['raw_usage'], isNull, reason: 'nothing has come back yet');
      observed = true;
    };
    try {
      await room.say(tester, '这句先留好');
      expect(observed, isTrue);
      expect(room.asked, hasLength(1));
      final receipt = room.memory.store.requests().single;
      expect(receipt['sent_at_ms'], isNotNull);
      expect(receipt['state'], 'finished');
      expect(receipt['terminal'], 'complete');
      expect(room.memory.store.hostChatDeliveries(), isEmpty);
      expect(room.client.prompts, isEmpty);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('a valid old host sends ordinary chat without a background memory warning or legacy recall', (
    tester,
  ) async {
    final room = _Room(root)..bridge.phoneMemory = false;
    await room.open(tester);
    try {
      expect(
        await settleMixed(tester, room.memory.migrateHost(room.client), limit: const Duration(seconds: 2)),
        isTrue,
        reason: 'a finished host migration must release its shared Future and allow a fresh complete read',
      );
      room.memory.store.saveManual(
        const CompanionMemory(id: '55555555-5555-4555-8555-555555555555', text: '喜欢淡茶'),
        expectedRowRev: null,
        currentValueChange: true,
        realityKnown: true,
      );
      await room.say(tester, '想喝什么');
      expect(room.asked, hasLength(1));
      expect(room.lastAsked(), contains('想喝什么'));
      expect(room.client.prompts, isEmpty);
      expect(room.bridge.prepared, isEmpty, reason: 'no Host prompt context is prepared for phone chat');
      expect(find.textContaining('这次聊天用不上她已经记住的事'), findsNothing);
      expect(room.memory.store.cards().single['text'], '喜欢淡茶');
      expect(room.memory.store.messages().where((row) => row['role'] == 'user').single['text'], '想喝什么');
      expect(room.bridge.binds, isEmpty, reason: 'unsupported phone context must not silently enable legacy recall');
    } finally {
      await room.close(tester);
    }
  });

  for (final failed in [false, true]) {
    testWidgets(
      'legacy recall cleanup ${failed ? 'keeps an unacknowledged identity' : 'retires without creating a replacement'}',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'companion_mode': 'full',
          'companion_touch_hint_done': true,
          'companion_home_hint_done': true,
          'companion_recall_bindings': jsonEncode({
            'local:${HostRef.local.id}': {'binding': _binding, 'session': 'old'},
          }),
        });
        final room = _Room(root)..bridge.failRevoke = failed;
        await room.open(tester);
        try {
          expect(room.bridge.revokes, isNotEmpty);
          expect(room.bridge.binds, isEmpty);
          final prefs = await SharedPreferences.getInstance();
          final stored = jsonDecode(prefs.getString('companion_recall_bindings') ?? '{}') as Map;
          expect(stored.containsKey('local:${HostRef.local.id}'), failed);
          await tester.tap(find.byIcon(AppIcons.more));
          await tester.pumpAndSettle();
          expect(find.text('完整模式里自动想起记忆'), findsNothing);
          expect(find.text('她记得的事'), findsOneWidget);
        } finally {
          await room.close(tester);
        }
      },
    );
  }
}
