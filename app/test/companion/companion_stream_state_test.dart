// The watch transport is synthetic; these sequences follow the real engine's
// failed-attempt/retry and committed-message contracts, including buffered frames.
// the wire decoder, ChatController, ChatTranscript, reply parser and page are real.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/chat/widgets/approval_card.dart';
import 'package:dsh_app/ui/companion/companion_ask.dart';
import 'package:dsh_app/ui/companion/companion_chrome.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _session = 'c438-synthetic-session';
const _now = 1793937600000;

class _Bridge extends DshConnection {
  _Bridge() : super(Uri.parse('http://127.0.0.1:9'));
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
  }) async => snapshot();
  @override
  Future<DshHttpResponse> postJson(String path, Object? body, {Duration? timeout}) async {
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

class _Client extends DshClient {
  _Client() : super(_Bridge());
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

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

class _Room {
  _Room(this.root);
  final Directory root;
  final client = _Client();
  final commands = <(String, Map<String, Object?>)>[];
  CompanionStageEvents? events;
  late ProviderContainer container;
  ChatState get state => container.read(chatProvider(_session));
  String? speech(WidgetTester tester) => tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text;
  List<String> get emotionNames => [
    for (final c in commands)
      if (c.$1 == 'emotion') c.$2['name']! as String,
  ];

  Future<void> open(WidgetTester tester) async {
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
    // Load the real persisted binding before stage ready, as the global filter
    // can do in the application. Do not replace CompanionSessions or chatProvider.
    container.read(companionSessionsProvider);
    await flush(tester);
    expect(container.read(companionSessionsProvider.notifier).of(HostRef.local)?.sessionId, _session);
    events!.onReady();
    await flush(tester);
    client.events.add(
      parseFollowFrame(_session, {
        'type': 'snapshot',
        'cursor': -1,
        'records': [],
        'assistantStream': {'revision': 0},
      }),
    );
    await flush(tester);
    expect(state.loading, isFalse);
    commands.clear();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
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

// Minimal relevant follow projection: durable seq and stream revision/index
// stay contiguous; upstream settlement logs the durable event before stream end.
class _Wire {
  _Wire(this.room);
  final _Room room;
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
    final event = parseFollowFrame(_session, frame);
    expect(event, isNot(isA<UnknownFrameEvent>()));
    room.client.events.add(event);
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

void _retry(_Wire wire, String nextAttempt) {
  const failure = {'code': 'TRANSPORT', 'message': 'Synthetic interrupted provider response'};
  wire.finish('error', failure);
  wire.settle('assistant/attempt');
  wire.log('llm/retry', {
    'turn': 1,
    'step': wire.step,
    'retryId': 'retry-$nextAttempt',
    'provider': 'synthetic',
    'mode': 'normal',
    'policyKey': 'synthetic',
    'retry': 1,
    'maxRetries': 5,
    'delayMs': 500,
    'failure': failure,
  });
  // The server waited; transport may buffer these frames and deliver them in
  // one app publication. This is not a zero-backoff server execution.
  wire.time += 500;
  wire.log('llm/retry-started', {'turn': 1, 'step': wire.step, 'retryId': 'retry-$nextAttempt', 'retry': 1});
  wire.start(nextAttempt);
}

void _commitToolPrefix(_Wire wire) {
  const text = '[动作:挥手]前面。';
  const call = {'type': 'tool-call', 'id': 'prefix-call', 'name': 'synthetic_lookup', 'arguments': '{}'};
  wire.start('prefix');
  wire.text(text);
  wire.endText();
  wire.chunk({'type': 'block-start', 'index': 1, 'blockType': 'tool-call'});
  wire.chunk({
    'type': 'tool-call-delta',
    'index': 1,
    'id': 'prefix-call',
    'name': 'synthetic_lookup',
    'argumentsDelta': '{}',
  });
  wire.chunk({'type': 'block-end', 'index': 1, 'block': call});
  wire.finish('tool-calls');
  wire.settle('assistant/message', text: text, extraParts: [call]);
  wire.log('tool/call', {'turn': 1, 'step': 1, 'callId': 'prefix-call', 'name': 'synthetic_lookup', 'arguments': '{}'});
  wire.log('tool/result', {
    'turn': 1,
    'step': 1,
    'message': {
      'id': 'prefix-result',
      'role': 'tool',
      'toolCallId': 'prefix-call',
      'content': [
        {'type': 'text', 'text': 'synthetic result'},
      ],
      'source': {'kind': 'tool'},
    },
  });
  wire.log('step/end', {'turn': 1, 'step': 1});
  wire.step = 2;
  wire.log('step/start', {'turn': 1, 'step': 2});
}

void main() {
  late Directory temporary;
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'companion_sessions': jsonEncode({
        '${HostRef.local.kind.name}:${HostRef.local.id}': {'id': _session, 'full': true},
      }),
    });
    temporary = Directory.systemTemp.createTempSync('c438-stream-');
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  testWidgets('positive control: empty start, monotonic chunks and repeated status preserve one reply', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      final wire = _Wire(room)
        ..beginTurn()
        ..start('positive');
      await flush(tester);
      expect(room.state.items.whereType<AssistantChatItem>(), isEmpty);
      wire.text('[表情:开心]你');
      await flush(tester);
      expect(room.speech(tester), '你');
      wire.text('好。');
      await flush(tester);
      expect(room.speech(tester), '你好。');
      final says = room.commands.where((c) => c.$1 == 'say').length;
      for (var i = 0; i < 3; i++) {
        room.client.events.add(const SessionStatusEvent(_session, true));
        await flush(tester);
      }
      expect(room.commands.where((c) => c.$1 == 'say').length, says);
      expect(room.emotionNames, ['happy']);
      wire.finish('stop');
      wire.settle('assistant/message', text: '[表情:开心]你好。');
      wire.endTurn();
      await flush(tester);
      expect(room.state.running, isFalse);
      expect(room.speech(tester), '你好。');
      expect(room.emotionNames, ['happy']);
      debugPrint(
        '[C439 POSITIVE] empty start -> monotonic chunks -> 3 same-session status notifications -> commit: OK',
      );
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('an approval waits for the command it is about before it can be allowed', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      final wire = _Wire(room)
        ..beginTurn()
        ..start('early-approval');
      wire.text('我看一下。');
      await flush(tester);
      // The approval arrives before its tool call has reached the transcript.
      room.client.events.add(
        HostEvent.fromFrame({
          'type': 'waterfall',
          'event': 'approval/request',
          'eventId': 'approval-early',
          'agentId': _session,
          'request': {'toolName': 'bash', 'callId': 'call-early'},
        }),
      );
      await flush(tester);
      expect(room.state.openApproval?.eventId, 'approval-early');
      expect(find.byType(ApprovalCard), findsNothing);
      // Its command comes in: now there is something to allow.
      wire.endText();
      const call = {'type': 'tool-call', 'id': 'call-early', 'name': 'bash', 'arguments': '{"command":"ls"}'};
      wire.chunk({'type': 'block-start', 'index': 1, 'blockType': 'tool-call'});
      wire.chunk({
        'type': 'tool-call-delta',
        'index': 1,
        'id': 'call-early',
        'name': 'bash',
        'argumentsDelta': '{"command":"ls"}',
      });
      wire.chunk({'type': 'block-end', 'index': 1, 'block': call});
      wire.finish('tool-calls');
      wire.settle('assistant/message', text: '我看一下。', extraParts: [call]);
      wire.log('tool/call', {
        'turn': 1,
        'step': 1,
        'callId': 'call-early',
        'name': 'bash',
        'arguments': '{"command":"ls"}',
      });
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(ApprovalCard), findsOneWidget);
      expect(find.textContaining('ls'), findsWidgets);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('an approval waits while its arguments are still arriving', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      final wire = _Wire(room)
        ..beginTurn()
        ..start('streaming-args');
      wire.text('我看一下。');
      wire.endText();
      wire.chunk({'type': 'block-start', 'index': 1, 'blockType': 'tool-call'});
      wire.chunk({
        'type': 'tool-call-delta',
        'index': 1,
        'id': 'call-streaming',
        'name': 'bash',
        'argumentsDelta': '{"command":"rm -',
      });
      await flush(tester);
      room.client.events.add(
        HostEvent.fromFrame({
          'type': 'waterfall',
          'event': 'approval/request',
          'eventId': 'approval-streaming',
          'agentId': _session,
          'request': {'toolName': 'bash', 'callId': 'call-streaming'},
        }),
      );
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 600));
      // Its call is there, its command half written: nothing to allow yet.
      expect(room.state.items.whereType<ToolChatItem>().single.status, ToolStatus.streaming);
      expect(find.byType(ApprovalCard), findsNothing);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('an approval whose call never shows up is shown after a short wait, as the main chat does', (
    tester,
  ) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      _Wire(room)
        ..beginTurn()
        ..start('lonely-approval');
      await flush(tester);
      room.client.events.add(
        HostEvent.fromFrame({
          'type': 'waterfall',
          'event': 'approval/request',
          'eventId': 'approval-lonely',
          'agentId': _session,
          'request': {'toolName': 'web_fetch', 'callId': 'call-elsewhere', 'reason': '要打开一个网页'},
        }),
      );
      await flush(tester);
      expect(find.byType(ApprovalCard), findsNothing);
      await tester.pump(CompanionAsk.detailWait);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(ApprovalCard), findsOneWidget);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('positive control: two assistant messages with tool and attention keep one accumulated reply', (
    tester,
  ) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      final wire = _Wire(room)
        ..beginTurn()
        ..start('tool-step');
      const first = '[表情:开心]我看一下。';
      const call = {'type': 'tool-call', 'id': 'call-positive', 'name': 'synthetic_lookup', 'arguments': '{}'};
      wire.text(first);
      wire.endText();
      wire.chunk({'type': 'block-start', 'index': 1, 'blockType': 'tool-call'});
      wire.chunk({
        'type': 'tool-call-delta',
        'index': 1,
        'id': 'call-positive',
        'name': 'synthetic_lookup',
        'argumentsDelta': '{}',
      });
      wire.chunk({'type': 'block-end', 'index': 1, 'block': call});
      wire.finish('tool-calls');
      wire.settle('assistant/message', text: first, extraParts: [call]);
      wire.log('tool/call', {
        'turn': 1,
        'step': 1,
        'callId': 'call-positive',
        'name': 'synthetic_lookup',
        'arguments': '{}',
      });
      room.client.events.add(
        HostEvent.fromFrame({
          'type': 'waterfall',
          'event': 'approval/request',
          'eventId': 'approval-positive',
          'agentId': _session,
          'request': {'toolName': 'synthetic_lookup', 'callId': 'call-positive'},
        }),
      );
      await flush(tester);
      expect(room.state.openApproval?.eventId, 'approval-positive');
      // Answered right here in the room, on her glass: no trip to the main chat.
      expect(find.byType(ApprovalCard), findsOneWidget);
      expect(room.speech(tester), '我看一下。');
      room.client.events.add(HostEvent.fromFrame({'type': 'cancel', 'eventId': 'approval-positive'}));
      wire.log('tool/result', {
        'turn': 1,
        'step': 1,
        'message': {
          'id': 'tool-result-positive',
          'role': 'tool',
          'toolCallId': 'call-positive',
          'content': [
            {'type': 'text', 'text': 'synthetic result'},
          ],
          'source': {'kind': 'tool'},
        },
      });
      wire.log('step/end', {'turn': 1, 'step': 1});
      wire.step = 2;
      wire.log('step/start', {'turn': 1, 'step': 2});
      wire.start('final-step');
      const second = '[动作:点头]查好了。';
      wire.text(second);
      await flush(tester);
      wire.finish('stop');
      wire.settle('assistant/message', text: second);
      wire.endTurn();
      await flush(tester);
      expect(room.state.items.whereType<UserChatItem>(), hasLength(1));
      expect(room.state.items.whereType<AssistantChatItem>().map((item) => item.text), [first, second]);
      expect(room.state.items.whereType<ToolChatItem>(), hasLength(1));
      expect(room.state.openApproval, isNull);
      // The card sinks away (its exit animation), then it is gone.
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(ApprovalCard), findsNothing);
      expect(room.speech(tester), '我看一下。\n查好了。');
      // She looks up once when the approval comes in, then nods at her answer.
      expect(room.emotionNames, ['surprised', 'happy']);
      expect(room.commands.where((c) => c.$1 == 'action').map((c) => c.$2['name']), ['lookUp', 'nod']);
      debugPrint(
        '[C439 POSITIVE] same user, two assistant messages, tool projection and attention enter/exit: OK; no actual tool executed',
      );
    } finally {
      await room.close(tester);
    }
  });

  for (final replacement in [
    (name: 'equal length', before: '[表情:开心]原句。', after: '[表情:担心]改句。', words: '改句。'),
    (name: 'marker only', before: '[表情:开心]好。', after: '[表情:担心]好。', words: '好。'),
  ]) {
    testWidgets('buffered retry with ${replacement.name} replaces draft without publishing an empty interval', (
      tester,
    ) async {
      final room = _Room(temporary);
      await room.open(tester);
      try {
        final wire = _Wire(room)
          ..beginTurn()
          ..start('first');
        wire.text(replacement.before);
        await flush(tester);
        final published = <ChatState>[];
        final listener = room.container.listen(chatProvider(_session), (_, next) => published.add(next));
        _retry(wire, 'second');
        wire.text(replacement.after);
        // One 32 ms publication sees the replacement live draft, no empty state.
        await flush(tester);
        expect(published, hasLength(1));
        expect(published.single.items.whereType<AssistantChatItem>().single.id, 'dsecond');
        expect(room.speech(tester), replacement.words);
        expect(room.emotionNames, ['happy', 'worried']);
        wire.finish('stop');
        wire.settle('assistant/message', text: replacement.after);
        wire.endTurn();
        await flush(tester);
        expect(room.emotionNames, ['happy', 'worried']);
        listener.close();
      } finally {
        await room.close(tester);
      }
    });
  }

  testWidgets('buffered failed draft to replacement durable message retires identical action once', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      final wire = _Wire(room)
        ..beginTurn()
        ..start('first');
      const text = '[动作:点头]好。';
      wire.text(text);
      await flush(tester);
      final published = <ChatState>[];
      final listener = room.container.listen(chatProvider(_session), (_, next) => published.add(next));
      _retry(wire, 'second');
      wire.text(text);
      wire.finish('stop');
      wire.settle('assistant/message', text: text);
      wire.endTurn();
      await flush(tester);
      expect(published, hasLength(1));
      expect(published.single.items.whereType<AssistantChatItem>().single.seq, isNotNull);
      expect(room.speech(tester), '好。');
      expect(room.commands.where((c) => c.$1 == 'action').map((c) => c.$2['name']), ['nod', 'nod']);
      room.client.events.add(const SessionStatusEvent(_session, false));
      await flush(tester);
      expect(room.commands.where((c) => c.$1 == 'action').length, 2);
      listener.close();
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('retry retires only failed suffix and keeps committed assistant prefix markers', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      final wire = _Wire(room)..beginTurn();
      _commitToolPrefix(wire);
      await flush(tester);
      expect(room.speech(tester), '前面。');
      wire.start('failed-suffix');
      wire.text('[表情:难过]这是一段没有成功的很长后半句。');
      await flush(tester);
      _retry(wire, 'good-suffix');
      wire.text('[表情:担心]好。');
      wire.finish('stop');
      wire.settle('assistant/message', text: '[表情:担心]好。');
      wire.endTurn();
      await flush(tester);
      expect(room.state.items.whereType<AssistantChatItem>(), hasLength(2));
      expect(room.speech(tester), '前面。\n好。');
      expect(room.commands.where((c) => c.$1 == 'action').map((c) => c.$2['name']), ['wave']);
      expect(room.emotionNames, ['sad', 'worried']);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('finish makes a draft nonstreaming before normal durable handoff without replay', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      final wire = _Wire(room)
        ..beginTurn()
        ..start('normal');
      const text = '[动作:点头]你好。';
      wire.text(text);
      await flush(tester);
      wire.finish('stop');
      await flush(tester);
      final finished = room.state.items.whereType<AssistantChatItem>().single;
      expect(finished.streaming, isFalse);
      expect(finished.seq, isNull);
      expect(finished.id, 'dnormal');
      wire.settle('assistant/message', text: text);
      wire.endTurn();
      await flush(tester);
      expect(room.state.items.whereType<AssistantChatItem>().single.seq, isNotNull);
      expect(room.speech(tester), '你好。');
      expect(room.commands.where((c) => c.$1 == 'action').map((c) => c.$2['name']), ['nod']);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('a split marker remains hidden until complete and does not replay on commit', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      final wire = _Wire(room)
        ..beginTurn()
        ..start('split');
      wire.text('[表情:担');
      await flush(tester);
      expect(room.emotionNames, isEmpty);
      wire.text('心]好。');
      await flush(tester);
      expect(room.speech(tester), '好。');
      expect(room.emotionNames, ['worried']);
      wire.finish('stop');
      wire.settle('assistant/message', text: '[表情:担心]好。');
      wire.endTurn();
      await flush(tester);
      expect(room.emotionNames, ['worried']);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('a new user can receive the same words after the old subtitle expired', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      final wire = _Wire(room)
        ..beginTurn()
        ..start('old-user');
      const text = '[动作:点头]好。';
      wire.text(text);
      await flush(tester);
      wire.finish('stop');
      wire.settle('assistant/message', text: text);
      wire.endTurn();
      await flush(tester);
      await tester.pump(const Duration(seconds: 10));
      expect(room.speech(tester), isNull);
      wire.time += 10000;
      wire.turn = 2;
      wire.beginTurn();
      wire.start('new-user');
      wire.text(text);
      wire.finish('stop');
      wire.settle('assistant/message', text: text);
      wire.endTurn();
      await flush(tester);
      expect(room.state.items.whereType<UserChatItem>(), hasLength(2));
      expect(room.speech(tester), '好。');
      expect(room.commands.where((c) => c.$1 == 'action').map((c) => c.$2['name']), ['nod', 'nod']);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('an unfinished literal marker revealed at turn end stays stable on duplicate notices', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      final wire = _Wire(room)
        ..beginTurn()
        ..start('literal');
      const text = '文字[表情:';
      wire.text(text);
      await flush(tester);
      expect(room.speech(tester), '文字');
      wire.finish('stop');
      wire.settle('assistant/message', text: text);
      wire.endTurn();
      await flush(tester);
      expect(room.speech(tester), text);
      final says = room.commands.where((c) => c.$1 == 'say').length;
      for (var i = 0; i < 3; i++) {
        room.client.events.add(const SessionStatusEvent(_session, false));
        await flush(tester);
      }
      expect(room.speech(tester), text);
      expect(room.commands.where((c) => c.$1 == 'say').length, says);
      expect(room.emotionNames, isEmpty);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('desired contract: successful shorter retry replaces failed attempt subtitle and marker', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      final wire = _Wire(room)
        ..beginTurn()
        ..start('failed');
      const oldText = '这是第一次尝试流出的很长一句话，还没有完成。';
      const oldMarked = '[表情:开心]$oldText';
      wire.text(oldMarked);
      await flush(tester);
      expect(room.speech(tester), oldText);
      expect(room.emotionNames, ['happy']);
      final userKey = room.state.items.whereType<UserChatItem>().single.key;
      const failure = {'code': 'TRANSPORT', 'message': 'Synthetic interrupted provider response'};
      wire.finish('error', failure);
      wire.settle('assistant/attempt');
      wire.log('llm/retry', {
        'turn': 1,
        'step': 1,
        'retryId': 'retry-c438',
        'provider': 'synthetic',
        'mode': 'normal',
        'policyKey': 'synthetic',
        'retry': 1,
        'maxRetries': 5,
        'delayMs': 500,
        'failure': failure,
      });
      await flush(tester);
      expect(room.state.items.whereType<AssistantChatItem>(), isEmpty);
      expect(room.speech(tester), isNull);
      expect(tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).thinking, isTrue);
      await tester.pump(const Duration(milliseconds: 500));
      wire.time += 500;
      wire.log('llm/retry-started', {'turn': 1, 'step': 1, 'retryId': 'retry-c438', 'retry': 1});
      wire.start('successful');
      const newMarked = '[表情:担心]好。';
      wire.text(newMarked);
      await flush(tester);
      wire.finish('stop');
      wire.settle('assistant/message', text: newMarked);
      wire.endTurn();
      await flush(tester);
      expect(room.state.items.whereType<UserChatItem>().single.key, userKey);
      expect(room.state.items.whereType<AssistantChatItem>().single.text, newMarked);
      expect(room.state.running, isFalse);
      final observed = {
        'userKey': userKey,
        'actualControllerText': room.state.items.whereType<AssistantChatItem>().single.text,
        'visibleSubtitle': room.speech(tester),
        'emotionCommands': room.emotionNames,
        'expectedSubtitle': '好。',
        'expectedNewEmotion': 'worried',
        'failedDraftRetired': true,
      };
      debugPrint('[C439 OBSERVED] ${jsonEncode(observed)}');
      // This assertion is deliberately a correct-behavior contract. It must
      // fail on the audited tree if the suspected visible regression exists.
      expect(room.speech(tester), '好。');
      expect(room.emotionNames, ['happy', 'worried']);
    } finally {
      await room.close(tester);
    }
  });
}
