// Delayed arrival reads must not replace newer room intent. The page,
// CompanionSessions, follow decoder and ChatController are real; the HTTP,
// session-read and watch transport boundaries are local synthetic fixtures.
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
import 'package:dsh_app/ui/companion/companion_chrome.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _session = 'synthetic-greeting-session';
const _now = 1793937600000;

class _Bridge extends DshConnection {
  _Bridge() : super(Uri.parse('http://127.0.0.1:9'));
  final initialRead = Completer<DshHttpResponse>();
  final posts = <Map<String, Object?>>[];
  final getPaths = <String>[];
  final postPaths = <String>[];
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
    getPaths.add(path);
    getCount++;
    return getCount == 1 ? initialRead.future : snapshot();
  }

  @override
  Future<DshHttpResponse> postJson(String path, Object? body, {Duration? timeout}) async {
    postPaths.add(path);
    posts.add(Map<String, Object?>.from(body! as Map));
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
  _Client(super.connection);
  final events = StreamController<DshEvent>();
  Completer<SessionProjections?>? projectionRead;
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
    return projectionRead?.future ?? SessionProjections.empty;
  }
}

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

class _Room {
  _Room(this.root);
  final Directory root;
  final bridge = _Bridge();
  late final client = _Client(bridge);
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

  void begin() {
    log('user/message', {
      'id': 'synthetic-user',
      'role': 'user',
      'content': [
        {'type': 'text', 'text': '说一句。'},
      ],
      'source': {'kind': 'user', 'rpcId': 'synthetic-request'},
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
    SharedPreferences.setMockInitialValues({
      'companion_sessions': jsonEncode({
        '${HostRef.local.kind.name}:${HostRef.local.id}': {'id': _session, 'full': true},
      }),
    });
    temporary = Directory.systemTemp.createTempSync('companion-greeting-');
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
}
