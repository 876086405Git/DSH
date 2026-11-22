// Delayed arrival reads must not replace newer room intent. The page,
// CompanionSessions, follow decoder and ChatController are real; the HTTP,
// session-read and watch transport boundaries are local synthetic fixtures.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/companion/companion_voice.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/companion/companion_chrome.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'companion_test_settle.dart';

const _session = 'synthetic-greeting-session';
const _now = 1793937600000;
const _voiceChannel = MethodChannel('dsh/companion_voice');

class _Bridge extends DshConnection {
  _Bridge() : super(Uri.parse('http://127.0.0.1:9'));
  final initialRead = Completer<DshHttpResponse>();
  final posts = <Map<String, Object?>>[];
  final getPaths = <String>[];
  final postPaths = <String>[];
  DshHttpResponse json(Object body, [int status = 200]) =>
      DshHttpResponse(status, 'application/json', Uint8List.fromList(utf8.encode(jsonEncode(body))));
  int revision = 0;
  int getCount = 0;
  DshHttpResponse snapshot() => DshHttpResponse(
    200,
    'application/json',
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'storeId': 'synthetic-greeting-store',
          'revision': revision,
          'memoryRevision': 0,
          'asOf': _now,
          'state': {'valence': 0.81, 'energy': 0.42, 'closeness': 0.33, 'activity': 'idle'},
        }),
      ),
    ),
  );
  void release() {
    if (!initialRead.isCompleted) initialRead.complete(snapshot());
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
    getPaths.add(path);
    getCount++;
    return getCount == 1 ? initialRead.future : snapshot();
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
  Future<DshHttpResponse> postJson(String path, Object? body, {Duration? timeout}) async {
    postPaths.add(path);
    posts.add(Map<String, Object?>.from(body! as Map));
    revision++;
    return snapshot();
  }
}

// 合成 HTTP 边界：两次 visit 分别发生于 12／6 小时前，本次合法增益
// 从 .02 到 .03。固定值遵守 state.js 的衰减、冷却和六小时间隔规则；
// 没有在此执行 Host 事务。提交后的原快照先保存，再扣住它的返回。
class _VisitBridge extends _Bridge {
  _VisitBridge() {
    revision = 2;
  }

  static const storeId = '44444444-4444-4444-8444-444444444444';
  final visitSeen = Completer<void>();
  final visitRelease = Completer<void>();
  final visitTimeouts = <Duration?>[];

  @override
  DshHttpResponse snapshot() => this.json({
    'storeId': storeId,
    'revision': revision,
    'memoryRevision': 0,
    'asOf': _now,
    'state': {
      'valence': revision == 2 ? 0.25007827758789064 : 0.2900782775878906,
      'energy': 0.75,
      'closeness': revision == 2 ? 0.02 : 0.03,
      'activity': 'idle',
      'activityUntil': null,
      'lastVisitAt': revision == 2 ? _now - 21600000 : _now,
      'lastInteractionAt': null,
      'thought': 'enjoy-company',
    },
  });

  void releaseVisit() {
    if (!visitRelease.isCompleted) visitRelease.complete();
  }

  @override
  Future<DshHttpResponse> postJson(String path, Object? body, {Duration? timeout}) async {
    if (path != '$dshGoCompanionPath/events') return super.postJson(path, body, timeout: timeout);
    final command = Map<String, Object?>.from(body! as Map<String, Object?>);
    posts.add(command);
    postPaths.add(path);
    visitTimeouts.add(timeout);
    if (!visitSeen.isCompleted) visitSeen.complete();
    if (command['storeId'] != storeId || command['expectedRevision'] != revision || command['type'] != 'visit') {
      return this.json({
        'error': {'code': 'companion/conflict'},
      }, 409);
    }
    revision++;
    final committed = snapshot();
    // 只记录原 SDK 传下来的 8 秒参数；替身不实现真实网络 timeout。
    await visitRelease.future;
    return committed;
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
  final events = StreamController<DshEvent>();
  Completer<SessionProjections?>? projectionRead;
  final projectionStarted = Completer<void>();
  int projectionCalls = 0;
  late final _fakeMux = _Mux(carrier);
  @override
  _Mux get mux => _fakeMux;
  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) {
    return events.stream;
  }

  @override
  Future<SessionProjections?> projections(String sessionId) async {
    projectionCalls++;
    if (!projectionStarted.isCompleted) projectionStarted.complete();
    return projectionRead?.future ?? SessionProjections.empty;
  }
}

class _PromptClient extends _Client {
  _PromptClient(super.connection);
  final prompts = <Map<String, Object?>>[];
  final promptSeen = Completer<String>();

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
    if (requestId == null) throw StateError('ChatController must supply its actual request id');
    prompts.add({
      'sessionId': sessionId,
      'text': text,
      'requestId': requestId,
      'images': images,
      'fileReceiptIds': fileReceiptIds,
      'mode': mode,
      'timeZone': timeZone,
    });
    if (!promptSeen.isCompleted) promptSeen.complete(requestId);
    return requestId;
  }
}

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

class _Room {
  _Room(this.root, {_Bridge? bridge, _Client? client}) : bridge = bridge ?? _Bridge(), _providedClient = client;
  final Directory root;
  final _Bridge bridge;
  final _Client? _providedClient;
  late final client = _providedClient ?? _Client(bridge);
  final commands = <(String, Map<String, Object?>)>[];
  CompanionStageEvents? events;
  late ProviderContainer container;
  ChatState get state => container.read(chatProvider(_session));
  String? speech(WidgetTester tester) => tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text;
  L10n l10n(WidgetTester tester) => L10n.of(tester.element(find.byType(CompanionPage)));

  void expectVisitAndVitals() {
    expect(bridge.getPaths, [dshGoCompanionPath]);
    expect(bridge.postPaths, ['$dshGoCompanionPath/events']);
    expect(bridge.posts, [
      {'storeId': 'synthetic-greeting-store', 'expectedRevision': 0, 'type': 'visit'},
    ]);
    expect(commands.where((command) => command.$1 == 'vitals').last.$2, {
      'valence': 0.81,
      'energy': 0.42,
      'closeness': 0.33,
    });
  }

  Future<void> open(WidgetTester tester, {Map<String, Object?>? initialSnapshot}) async {
    Directory('${root.path}/pack/runtime').createSync(recursive: true);
    Directory('${root.path}/pack/character').createSync(recursive: true);
    File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
    File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeHostProvider.overrideWith(_Host.new),
          activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: true))),
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
    container.read(companionSessionsProvider);
    final memory = await tester.runAsync(() => container.read(companionMemoryOwnerProvider(root.absolute.path).future));
    await tester.pump();
    await settleMixed(tester, memory!.migrateLocal());
    await flush(tester);
    expect(container.read(companionSessionsProvider.notifier).of(HostRef.local)?.sessionId, _session);
    events!.onReady();
    await flush(tester);
    client.events.add(
      parseFollowFrame(
        _session,
        initialSnapshot ??
            {
              'type': 'snapshot',
              'cursor': -1,
              'records': [],
              'assistantStream': {'revision': 0},
            },
      ),
    );
    await flush(tester);
    expect(state.loading, isFalse);
    expect(bridge.getCount, 1);
    commands.clear();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    bridge.release();
    final read = client.projectionRead;
    if (read != null && !read.isCompleted) read.complete(SessionProjections.empty);
    await tester.pump();
    await tester.runAsync(() async {
      await client.events.close();
      await client.mux.connection.close();
      await client.close();
    });
  }
}

Future<void> flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 40));
  await tester.pump();
}

Future<void> _voiceEvent(WidgetTester tester, Map<String, Object?> args) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _voiceChannel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('event', args)),
      (_) {},
    );

// Source-derived follow events. A full message may be coalesced into one page
// publication; durable sequence, stream revision and attempt index stay valid.
class _Wire {
  _Wire([this.room]);
  final _Room? room;
  final frames = <Map<String, Object?>>[];
  int seq = -1;
  int revision = 0;
  int index = 0;
  final chunks = <Map<String, Object?>>[];
  void frame(Map<String, Object?> value) {
    frames.add(value);
    final event = parseFollowFrame(_session, value);
    expect(event, isNot(isA<UnknownFrameEvent>()));
    room?.client.events.add(event);
  }

  void log(String type, Map<String, Object?> data) => frame({
    'type': 'event',
    'event': {'type': type, 'seq': ++seq, 'time': _now, 'data': data},
  });

  void begin({String text = '说一句。', String requestId = 'synthetic-request'}) {
    log('user/message', {
      'id': 'synthetic-user',
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text},
      ],
      'source': {'kind': 'user', 'rpcId': requestId},
    });
    log('turn/start', {'turn': 1});
    log('step/start', {'turn': 1, 'step': 1});
  }

  void chunk(Map<String, Object?> value) {
    chunks.add({'type': 'chunk', 'time': _now, 'chunk': value});
    frame({
      'type': 'assistant-stream',
      'frame': {
        'type': 'chunk',
        'attemptId': 'synthetic-attempt',
        'revision': ++revision,
        'index': index++,
        'time': _now,
        'chunk': value,
      },
    });
  }

  void answer(String text) {
    frame({
      'type': 'assistant-stream',
      'frame': {
        'type': 'start',
        'attemptId': 'synthetic-attempt',
        'revision': ++revision,
        'turn': 1,
        'step': 1,
        'startedAfterSeq': seq,
      },
    });
    chunk({'type': 'block-start', 'index': 0, 'blockType': 'text'});
    chunk({'type': 'text-delta', 'index': 0, 'text': text});
    chunk({
      'type': 'block-end',
      'index': 0,
      'block': {'type': 'text', 'text': text},
    });
    chunk({
      'type': 'finish',
      'reason': {'kind': 'stop'},
    });
    log('assistant/message', {
      'turn': 1,
      'step': 1,
      'stream': List.of(chunks),
      'message': {
        'id': 'synthetic-assistant',
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': text},
        ],
        'source': {'kind': 'model', 'provider': 'synthetic', 'model': 'synthetic'},
      },
    });
    frame({
      'type': 'assistant-stream',
      'frame': {
        'type': 'end',
        'attemptId': 'synthetic-attempt',
        'revision': ++revision,
        'index': index,
        'outcome': {'kind': 'committed', 'eventType': 'assistant/message', 'seq': seq},
      },
    });
    log('step/end', {'turn': 1, 'step': 1});
    log('turn/end', {
      'turn': 1,
      'reason': {'kind': 'completed'},
    });
  }

  void stopBeforeText() {
    log('step/end', {'turn': 1, 'step': 1});
    log('turn/end', {
      'turn': 1,
      'reason': {
        'kind': 'aborted',
        'reason': {'kind': 'user'},
      },
    });
  }

  Map<String, Object?> snapshot() => {
    'type': 'snapshot',
    'cursor': seq,
    'records': [
      for (final frame in frames)
        if (frame['type'] == 'event') {'event': frame['event']},
    ],
    'assistantStream': {'revision': revision},
  };
}

void main() {
  late Directory temporary;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('companion-greeting-');
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

  testWidgets('a quiet delayed arrival greets and still records its visit and vitals', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      expect(room.speech(tester), isNull);
      room.bridge.release();
      await flush(tester);
      // This pack has no name: she introduces herself without one.
      expect(room.speech(tester), room.l10n(tester).companionGreetFirstNameless);
      room.expectVisitAndVitals();
      expect(room.commands.where((command) => command.$1 == 'say'), hasLength(1));
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('a touch supersedes a pending greeting without dropping visit state', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      room.events!.onTouch('face', 'tap');
      await tester.pump();
      final line = room.speech(tester);
      expect(line, isNotNull);
      room.bridge.release();
      await flush(tester);
      room.expectVisitAndVitals();
      expect(room.speech(tester), line);
      expect(room.commands.where((command) => command.$1 == 'say'), hasLength(1));
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('a late greeting cannot cancel the snack line before its timer fires', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      final l10n = room.l10n(tester);
      room.events!.onObject('snack');
      await tester.pump(const Duration(milliseconds: 100));
      expect(room.speech(tester), isNull);
      room.bridge.release();
      await flush(tester);
      final afterRead = room.speech(tester);
      room.expectVisitAndVitals();
      await tester.pump(const Duration(milliseconds: 1700));
      await tester.pump();
      debugPrint(
        '[C442 SNACK] ${jsonEncode({'afterRead': afterRead, 'afterTimer': room.speech(tester), 'posts': room.bridge.posts})}',
      );
      expect(room.speech(tester), isIn([l10n.companionSnack1, l10n.companionSnack2, l10n.companionSnack3]));
      expect(afterRead, isNull);
      expect(room.commands.where((command) => command.$1 == 'say'), hasLength(1));
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('an accepted send awaiting its session read already supersedes the greeting', (tester) async {
    final room = _Room(temporary);
    room.client.projectionRead = Completer<SessionProjections?>();
    await room.open(tester);
    try {
      await tester.enterText(find.byType(TextField), '稍等这一句');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      await settleMixed(tester, room.client.projectionStarted.future);
      await flush(tester);
      expect(room.client.projectionCalls, 1);
      expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isTrue);
      room.bridge.release();
      await flush(tester);
      room.expectVisitAndVitals();
      expect(room.speech(tester), isNull);
      expect(tester.widget<CompanionMyLine>(find.byType(CompanionMyLine)).text, '稍等这一句');
      expect(room.commands.where((command) => command.$1 == 'say'), isEmpty);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('becoming idle before the arrival read finishes does not revive its greeting', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      final wire = _Wire(room)..begin();
      await flush(tester);
      expect(room.state.running, isTrue);
      expect(room.speech(tester), isNull);
      wire.stopBeforeText();
      await flush(tester);
      expect(room.state.running, isFalse);
      expect(room.state.error, isNull);
      expect(room.speech(tester), isNull);
      room.bridge.release();
      await flush(tester);
      room.expectVisitAndVitals();
      expect(room.speech(tester), isNull);
      expect(room.commands.where((command) => command.$1 == 'say'), isEmpty);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('a marker-only reply coalesced through completion supersedes a pending greeting', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      _Wire(room)
        ..begin()
        ..answer('[表情:担心]');
      await flush(tester);
      expect(room.state.running, isFalse);
      expect(room.state.items.whereType<AssistantChatItem>().single.text, '[表情:担心]');
      expect(room.speech(tester), isNull);
      room.bridge.release();
      await flush(tester);
      room.expectVisitAndVitals();
      expect(room.speech(tester), isNull);
      expect(room.commands.where((command) => command.$1 == 'emotion').map((command) => command.$2['name']), [
        'worried',
      ]);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('old idle history and an unchanged status notification still permit the arrival greeting', (
    tester,
  ) async {
    final history = _Wire()
      ..begin()
      ..answer('[表情:开心]以前说过。');
    final room = _Room(temporary);
    await room.open(tester, initialSnapshot: history.snapshot());
    try {
      expect(room.state.running, isFalse);
      expect(room.state.items.whereType<AssistantChatItem>().single.text, '[表情:开心]以前说过。');
      expect(room.speech(tester), isNull);
      room.client.events.add(const SessionStatusEvent(_session, false));
      await flush(tester);
      room.bridge.release();
      await flush(tester);
      room.expectVisitAndVitals();
      // This pack has no name: she introduces herself without one.
      expect(room.speech(tester), room.l10n(tester).companionGreetFirstNameless);
      expect(room.commands.where((command) => command.$1 == 'emotion').map((command) => command.$2['name']), ['shy']);
    } finally {
      await room.close(tester);
    }
  });

  for (final (name, finishedBeforeVisit) in const [
    ('R23 a delayed visit after text completion keeps the current voice', false),
    ('R23 a delayed visit after voice completion still gives one closer line', true),
  ]) {
    testWidgets(name, (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('companion_voice_enabled', true);
      await prefs.setString('companion_voice_v1', '{"source":"system"}');
      final bridge = _VisitBridge();
      final client = _PromptClient(bridge);
      final room = _Room(temporary, bridge: bridge, client: client);
      final calls = <MethodCall>[];
      final ready = Completer<void>();
      final spoke = Completer<Map<String, Object?>>();
      final heard = <CompanionVoiceEvent>[];
      StreamSubscription<CompanionVoiceEvent>? subscription;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_voiceChannel, (call) async {
        calls.add(call);
        if (call.method == 'ready' && !ready.isCompleted) ready.complete();
        if (call.method == 'speak' && !spoke.isCompleted) {
          spoke.complete(Map<String, Object?>.from(call.arguments! as Map<Object?, Object?>));
        }
        return switch (call.method) {
          'ready' || 'speak' => true,
          _ => null,
        };
      });
      List<Map<String, Object?>> spoken() => [
        for (final call in calls)
          if (call.method == 'speak') Map<String, Object?>.from(call.arguments! as Map<Object?, Object?>),
      ];
      int stops() => calls.where((call) => call.method == 'stop').length;
      int hops() => room.commands.where((command) => command.$1 == 'action' && command.$2['name'] == 'hop').length;
      final sayCommands = room.commands.where((command) => command.$1 == 'say');
      try {
        await room.open(tester);
        await settleMixed(tester, ready.future);
        subscription = room.container.read(companionSpeakerProvider).events.listen(heard.add);
        expect(spoken(), isEmpty);

        const said = '今天走了一段路。';
        const reply = '辛苦啦，慢慢说，我在听。';
        await tester.enterText(find.byType(TextField), said);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('send')));
        final requestId = await settleMixed(tester, client.promptSeen.future);
        await flush(tester);
        expect(client.prompts, [
          {
            'sessionId': _session,
            'text': said,
            'requestId': requestId,
            'images': <PromptImage>[],
            'fileReceiptIds': <String>[],
            'mode': PromptMode.queue,
            'timeZone': null,
          },
        ]);
        expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
        expect(room.state.error, isNull);
        final wire = _Wire(room)..begin(text: said, requestId: requestId);
        await flush(tester);
        expect(room.state.running, isTrue);

        // 原 _arrive GET 只有 3 秒外层期限；在任何秒级 pump 前放回它。
        // 此时普通发送已收尾，欢迎已退休，visit 仍沿真实原快照提交。
        bridge.release();
        await settleMixed(tester, bridge.visitSeen.future);
        await flush(tester);
        expect(bridge.getCount, 1);
        expect(bridge.posts, [
          {'storeId': _VisitBridge.storeId, 'expectedRevision': 2, 'type': 'visit'},
        ]);
        expect(bridge.visitTimeouts, [const Duration(seconds: 8)]);
        expect(bridge.revision, 3);
        expect(bridge.visitRelease.isCompleted, isFalse);
        expect(room.commands.where((command) => command.$1 == 'vitals').last.$2['closeness'], 0.02);
        expect(spoken(), isEmpty);

        wire.answer(reply);
        final speech = await settleMixed(tester, spoke.future);
        await flush(tester);
        expect(room.state.running, isFalse);
        expect(room.state.pending, isEmpty);
        expect(room.state.error, isNull);
        expect(tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy, isFalse);
        expect(room.state.items.whereType<AssistantChatItem>().single.text, reply);
        expect(room.speech(tester), reply);
        expect(speech['text'], reply);
        expect(speech['flush'], isFalse);
        final id = speech['id']! as String;
        final beforeStart = sayCommands.length;
        await _voiceEvent(tester, {'type': 'start', 'id': id});
        await _voiceEvent(tester, {'type': 'range', 'id': id, 'start': 0, 'end': 2});
        await flush(tester);
        expect(heard.where((event) => event.id == id).map((event) => event.type), [
          CompanionVoiceEventType.start,
          CompanionVoiceEventType.range,
        ]);
        expect(sayCommands.skip(beforeStart).map((command) => command.$2['chars']), [reply.length, 2]);

        if (finishedBeforeVisit) {
          await _voiceEvent(tester, {'type': 'done', 'id': id});
          await flush(tester);
          expect(heard.last.type, CompanionVoiceEventType.done);
          // 原嘴型收束最多 4 秒；不延长 GET、POST 或测试期限。
          await tester.pump(const Duration(seconds: 4));
        }
        final beforeStops = stops();
        final beforeSpoken = spoken().length;
        final beforeHops = hops();
        final closer = room.l10n(tester).companionCloser1;
        bridge.releaseVisit();
        await flush(tester);
        expect(room.commands.where((command) => command.$1 == 'vitals').last.$2, {
          'valence': 0.2900782775878906,
          'energy': 0.75,
          'closeness': 0.03,
        });
        expect(hops(), beforeHops + 1, reason: 'The held visit was actually applied, including its closer action');
        expect(room.commands.where((command) => command.$1 == 'emotion').last.$2['name'], 'happy');

        if (!finishedBeforeVisit) {
          expect(room.speech(tester), reply);
          expect(stops(), beforeStops);
          expect(spoken(), hasLength(beforeSpoken));
          expect(spoken().where((call) => call['text'] == closer), isEmpty);
          final beforeRange = sayCommands.length;
          await _voiceEvent(tester, {'type': 'range', 'id': id, 'start': 2, 'end': 5});
          await flush(tester);
          expect(sayCommands.skip(beforeRange).map((command) => command.$2['chars']), [3]);
          await _voiceEvent(tester, {'type': 'done', 'id': id});
          await flush(tester);
          expect(heard.last.type, CompanionVoiceEventType.done);
          await tester.pump(const Duration(seconds: 4));
          expect(stops(), beforeStops);
          expect(spoken().map((call) => call['text']), [
            reply,
          ], reason: 'No deferred closer line after voice completion');
        } else {
          expect(room.speech(tester), closer);
          expect(spoken().map((call) => call['text']), [reply, closer]);
          final next = spoken().last;
          expect(next['id'], isNot(id));
          expect(next['flush'], isTrue);
          await _voiceEvent(tester, {'type': 'start', 'id': next['id']});
          await _voiceEvent(tester, {'type': 'range', 'id': next['id'], 'start': 0, 'end': 2});
          await _voiceEvent(tester, {'type': 'done', 'id': next['id']});
          await flush(tester);
          expect(heard.where((event) => event.id == next['id']).map((event) => event.type), [
            CompanionVoiceEventType.start,
            CompanionVoiceEventType.range,
            CompanionVoiceEventType.done,
          ]);
          client.events.add(const SessionStatusEvent(_session, false));
          await flush(tester);
          expect(spoken().where((call) => call['text'] == closer), hasLength(1));
        }
        expect(client.prompts, hasLength(1));
        expect(bridge.postPaths, ['$dshGoCompanionPath/events'], reason: 'Ordinary chat did not submit another visit');
      } finally {
        bridge.release();
        bridge.releaseVisit();
        await subscription?.cancel();
        try {
          await room.close(tester);
        } finally {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_voiceChannel, null);
        }
      }
    });
  }
}
