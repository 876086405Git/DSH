// The real room and ChatController use a scripted Session log and bridge.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/links/launcher_entries.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/widgets/approval_card.dart';
import 'package:dsh_app/ui/companion/companion_ask.dart';
import 'package:dsh_app/ui/companion/companion_chrome.dart';
import 'package:dsh_app/ui/companion/companion_log.dart';
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
import '../support/companion_session_peer.dart';
import 'companion_test_settle.dart';

const _store = '33333333-3333-4333-8333-333333333333';
const _epoch = '44444444-4444-4444-8444-444444444444';
const _binding = '22222222-2222-4222-8222-222222222222';

class _Bridge extends DshConnection {
  _Bridge() : super(Uri.parse('http://127.0.0.1:9'));
  String instance = 'first-instance';
  final phoneSessions = <String>{};
  String? rejectPrepare;
  String? deviceConflict;
  bool failRevoke = false;
  bool chatUsage = false;
  bool phoneMemory = true;
  final prepared = <Map<String, Object?>>[];
  final boundSessions = <String>{};
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
    if (phoneMemory) 'phoneMemoryVersion': 3,
    if (phoneMemory) 'selectedPage': true,
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
  }) => path.endsWith('/session-tools/open')
      ? Future.value(deviceConflict == null
          ? DshHttpStreamResponse(404, 'text/plain', const Stream.empty(), () async {})
          : DshHttpStreamResponse(409, 'application/json', Stream.value(json({
              'error': {'code': deviceConflict, 'message': 'fixture text'},
            }).body), () async {}))
      : host!.connection.postJsonStream(
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
    if (path == '/api/agentPresets/list' || path == '/api/agentPresets/select' || path == '/api/session/projections') {
      final envelope = body! as Map;
      final args = (envelope['payload'] as Map)['args'] as Map;
      final Object? result;
      if (path == '/api/agentPresets/list') {
        result = {'presets': [{'id': companionPresetId}]};
      } else if (path == '/api/agentPresets/select') {
        final id = args['agentId']! as String;
        expect(args['agentPreset'], companionPresetId);
        boundSessions.add(id);
        result = companionPresetId;
      } else {
        final id = (args['request'] as Map)['sessionId'];
        result = boundSessions.contains(id) ? {'asOfSeq': -1, 'values': {'agentPreset': companionPresetId}} : null;
      }
      return json({'type': 'server-response', 'rpcId': envelope['rpcId'], 'result': {'ok': true, 'value': result}});
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

// Room ownership and persisted role keys stay with the real CompanionSessions.
class _Sessions extends SessionsController {
  int created = 0;

  @override
  Future<List<SessionSummary>> build() async => const [];

  @override
  Future<String> createForConnection(HostConnection conn, {required bool Function() isCurrent, bool autoApprove = true}) async {
    expect(isCurrent(), isTrue);
    expect(autoApprove, isFalse);
    return 'fresh-${++created}';
  }
}

class _Room {
  _Room(this.root);
  final Directory root;
  final bridge = _Bridge();
  late final client = CompanionSessionPeer(bridge);
  final sessions = _Sessions();
  late CompanionMemoryOwner memory;
  CompanionStageEvents? events;
  final actions = <String>[];
  final emotions = <String>[];

  /// Auxiliary traffic is recorded independently from session/prompt.
  final asked = <Map<String, Object?>>[];
  String reply = '嗯，我在。';

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  http.Client model() => MockClient.streaming((request, body) async {
    final sent = jsonDecode(await body.bytesToString()) as Map<String, Object?>;
    asked.add(sent);
    return http.StreamedResponse(
      Stream.value(utf8.encode(_reply(reply))),
      200,
      headers: {'content-type': 'text/event-stream; charset=utf-8'},
    );
  });

  Future<void> open(WidgetTester tester, {String? page}) async {
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
          sessionsProvider.overrideWith(() => sessions),
          settingsProvider.overrideWith(_Settings.new),
          companionLightClientProvider.overrideWithValue(model),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('zh'),
          home: CompanionPage(
            assistantEntry: page == null ? null : CompanionAssistantEntry(page: page),
            storeOverride: CompanionPackStore(root),
            stageController: CompanionStageController(sink: (type, args) {
              if (type == 'action') actions.add(args['name'] as String);
              if (type == 'emotion') emotions.add(args['name'] as String);
            }),
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

  testWidgets('full room sends verbatim to the bound session with one sidecar and one local source', (tester) async {
    final room = _Room(root);
    await room.open(tester);
    try {
      expect(room.sessions.created, 0, reason: 'opening the room does not create a Host session');
      const raw = '  读一下说明，再改脚本。\n';
      await room.say(tester, raw);
      final sent = room.client.prompts.single;
      final prepared = room.bridge.prepared.single;
      expect(room.sessions.created, 1);
      expect(sent.session, 'fresh-1');
      expect(sent.text, raw);
      expect(prepared['requestId'], sent.requestId);
      expect(prepared['sessionId'], sent.session);
      expect(prepared['deviceContext'], containsPair('window', 'room'));
      final memory = prepared['phoneMemory']! as Map;
      expect(jsonDecode(memory['block']! as String), containsPair('version', 3));
      expect(room.memory.store.messages().where((row) => row['role'] == 'user').single['text'], raw);
      expect(room.asked, isEmpty, reason: 'the phone never starts a second foreground tool loop');
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('DSH draft, durable message and second step share one bubble and run one stage action', (tester) async {
    final room = _Room(root)..bridge.chatUsage = true;
    await room.open(tester);
    final commit = room.client.releaseCommit = Completer<void>();
    try {
      await room.say(tester, '看看文件');
      expect(tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text, '找到文件了。');
      expect(room.actions.where((action) => action == 'nod'), hasLength(1));
      final session = room.client.prompts.single.session;
      final ask = find.byType(CompanionAsk);
      expect(tester.widget<CompanionAsk>(ask).sessionId, session);
      const approvalId = 'room-read-preview';
      room.client.hostEvent(session, {
        'type': 'waterfall', 'event': 'approval/request', 'eventId': approvalId,
        'agentId': session, 'request': {'toolName': 'read_file', 'reason': 'Read the fixture preview'},
      });
      await room.settle(tester);
      final card = tester.widget<ApprovalCard>(find.descendant(of: ask, matching: find.byType(ApprovalCard)));
      expect((card.request.sessionId, card.request.eventId), (session, approvalId));
      room.client.hostEvent(session, {'type': 'cancel', 'eventId': approvalId});
      expect(room.memory.store.messages().where((r) => r['role'] == 'assistant'), isEmpty);
      commit.complete();
      await room.settle(tester);
      expect(tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text, '找到文件了。\n里面有三行。');
      expect(room.actions.where((action) => action == 'nod'), hasLength(1));
      expect(room.memory.store.messages().where((r) => r['role'] == 'assistant').single['text'],
          '[动作:点头]找到文件了。\n里面有三行。');
      expect(room.memory.store.hostChatDeliveries().single['request_id'], room.client.prompts.single.requestId);
      tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).onPullBack!();
      await room.settle(tester);
      await tester.pump(const Duration(milliseconds: 500));
      final log = tester.widget<CompanionLog>(find.byType(CompanionLog));
      expect(log.entries.map((e) => e.text), ['看看文件', '找到文件了。', '里面有三行。']);
    } finally {
      if (!commit.isCompleted) commit.complete();
      await room.close(tester);
    }
  });

  testWidgets('two full room turns keep one session and present only their own marks', (tester) async {
    final room = _Room(root);
    const first = '今天散步看到一片落叶。';
    const second = '你呢？';
    const firstReply = '[表情:开心]我也喜欢落叶。';
    const secondReply = '[动作:点头]今天的阳光很暖。';
    room.client.scriptedWords.addAll({first: firstReply, second: secondReply});
    await room.open(tester);
    try {
      // Initial greeting effects are independent of these two user prompts.
      room.emotions.clear();
      room.actions.clear();
      await room.say(tester, first);
      expect(tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text, '我也喜欢落叶。');
      expect(room.emotions.where((name) => name == 'happy'), hasLength(1));
      await room.say(tester, second);
      expect(tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text, '今天的阳光很暖。');
      expect(room.emotions.where((name) => name == 'happy'), hasLength(1));
      expect(room.actions.where((name) => name == 'nod'), hasLength(1));
      final prompts = room.client.prompts;
      expect(prompts.map((p) => p.text), [first, second]);
      expect(prompts.map((p) => p.session).toSet(), hasLength(1));
      expect(prompts.map((p) => p.requestId).toSet(), hasLength(2));
      expect(room.bridge.prepared.map((p) => p['requestId']), prompts.map((p) => p.requestId));
      final saved = room.memory.store.messages().where((row) => row['role'] == 'assistant');
      expect(saved.map((row) => row['text']), unorderedEquals([firstReply, secondReply]));
      expect(room.asked, isEmpty);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('Android assistant shares the page with exactly one full room request', (tester) async {
    final room = _Room(root);
    const page = '列车将在九点到站。';
    await room.open(tester, page: page);
    try {
      await room.say(tester, '几点到站？');
      expect(room.client.prompts.single.text, '几点到站？');
      final first = room.bridge.prepared.single;
      expect(first['requestId'], room.client.prompts.single.requestId);
      expect(first['deviceContext'], containsPair('selectedPage', page));
      await room.say(tester, '谢谢');
      expect(room.client.prompts.last.session, room.client.prompts.first.session);
      expect(room.bridge.prepared.last['deviceContext'] as Map, isNot(contains('selectedPage')));
      expect(room.asked, isEmpty);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('unknown prompt result keeps its original id, context and SQLite source for an explicit retry', (
    tester,
  ) async {
    final room = _Room(root);
    await room.open(tester);
    try {
      const raw = ' 这次请保留原文 ';
      room.client.dropNext = true;
      await room.say(tester, raw);
      final first = room.client.prompts.single;
      final snapshot = room.bridge.prepared.single;
      final source = room.memory.store.messages().single;
      await tester.pump(const Duration(seconds: 2));
      expect(room.client.prompts, hasLength(1));
      expect(room.asked, isEmpty);
      await room.say(tester, raw);
      expect(room.client.prompts, [first, first]);
      expect(room.bridge.prepared, [snapshot, snapshot]);
      expect(room.memory.store.messages().where((row) => row['role'] == 'user').single['id'], source['id']);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('a device conflict on retry uses the already delivered Host turn', (tester) async {
    final room = _Room(root);
    await room.open(tester);
    try {
      const raw = '核对这次请求';
      room.client.dropNext = true;
      await room.say(tester, raw);
      final first = room.client.prompts.single;
      await room.client.completeOriginal(first.session, first.text, first.requestId);
      await room.settle(tester);
      room.bridge.deviceConflict = 'companion/device-connection-replaced';
      await room.say(tester, raw);
      expect(room.client.prompts, [first]); // The retry consumed the existing receipt.
      expect(room.asked, isEmpty);
      expect(room.memory.store.messages().where((r) => r['role'] == 'assistant').single['text'], '会话回复');
      expect(tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text, '会话回复');
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('Stop after prompt handoff waits for the exact source echo and then cancels its turn once', (
    tester,
  ) async {
    final room = _Room(root);
    await room.open(tester);
    try {
      final echo = room.client.releaseEcho = Completer<void>();
      await room.say(tester, '等我的工具回合');
      expect(room.client.prompts, hasLength(1));
      await tester.tap(find.byIcon(AppIcons.stopGenerating).first);
      await room.settle(tester);
      expect(room.client.cancelledSessions, isEmpty, reason: 'a different or unidentified turn must not be stopped');
      echo.complete();
      await room.settle(tester);
      expect(room.client.cancelledSessions, [room.client.prompts.single.session]);
      expect(room.client.prompts, hasLength(1));
      expect(room.asked, isEmpty);
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
      expect(room.asked, isEmpty);
      expect(room.client.prompts.single.text, '想喝什么');
      expect(room.bridge.prepared.single.containsKey('phoneMemory'), isFalse);
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
