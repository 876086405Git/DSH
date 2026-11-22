// Delayed arrival reads must not replace newer room intent. The page,
// CompanionSessions, the phone model loop and its SSE reader are real; the
// Host HTTP and the model's HTTP response are local synthetic fixtures.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_keeper.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/companion_agent_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/companion/companion_chrome.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'companion_test_settle.dart';
import 'phone_keeper_fake.dart';

const _session = 'synthetic-greeting-session';
const _now = 1793937600000;

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

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true, apiKey: 'synthetic-test-key');
}

// Only the public phone storage boundary is held. The real Page/Agent still
// decides when to greet, retires newer intent, and serializes its visit event.
class _Phone extends FakePhoneKeeper {
  _Phone() : super(state: FakePhoneKeeper.snapshotOf(closeness: 0.33));

  final readStarted = Completer<void>();
  final initialRead = Completer<CompanionSnapshot?>();
  final writes = <(CompanionSnapshot, String)>[];
  int reads = 0;

  @override
  Future<CompanionSnapshot?> snapshot() {
    reads++;
    if (!readStarted.isCompleted) readStarted.complete();
    return initialRead.future;
  }

  void release() {
    if (!initialRead.isCompleted) initialRead.complete(state);
  }

  @override
  Future<CompanionSnapshot> event(CompanionSnapshot read, String type) {
    writes.add((read, type));
    return super.event(read, type);
  }
}

class _Room {
  _Room(this.root);
  final Directory root;
  final bridge = _Bridge();
  final phone = _Phone();
  Directory? phoneDirectory;
  late final client = _Client(bridge);
  final commands = <(String, Map<String, Object?>)>[];
  CompanionStageEvents? events;
  late ProviderContainer container;
  late CompanionMemoryOwner memory;

  /// The room's chat is the phone model loop in either mode: what it asked,
  /// and the Messages stream each request is answered with.
  final asked = <Map<String, Object?>>[];
  final replies = <StreamController<List<int>>>[];
  http.Client newClient() => MockClient.streaming((request, body) async {
    asked.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
    final reply = StreamController<List<int>>();
    replies.add(reply);
    return http.StreamedResponse(reply.stream, 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
  });

  bool get running => tester.widget<CompanionComposer>(find.byType(CompanionComposer)).running;
  late WidgetTester tester;

  void words(String text) => replies.last.add(
    utf8.encode(
      'data: ${jsonEncode({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': text},
      })}\n\n',
    ),
  );

  /// Ends the current model request as a finished turn without any tool.
  Future<void> finish() async {
    replies.last.add(
      utf8.encode(
        'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}\n\n'
        'data: {"type":"message_stop"}\n\n',
      ),
    );
    unawaited(replies.last.close());
    for (var i = 0; i < 100 && running; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    await flush(tester);
  }

  Future<void> send(String text) async {
    final before = asked.length;
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send')));
    for (var i = 0; i < 100 && asked.length == before; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(asked, hasLength(before + 1));
    await flush(tester);
  }

  String? speech(WidgetTester tester) => tester.widget<CompanionSpeech>(find.byType(CompanionSpeech)).text;
  L10n l10n(WidgetTester tester) => L10n.of(tester.element(find.byType(CompanionPage)));

  void expectVisitAndVitals() {
    expect(phone.reads, 1);
    expect(phone.writes.map((write) => write.$2), ['visit']);
    expect(phone.writes.single.$1.revision, 0);
    expect(phone.state!.revision, 1);
    expect(bridge.posts, isEmpty);
    final vitals = phone.state!.vitals;
    expect(commands.where((command) => command.$1 == 'vitals').last.$2, {
      'valence': vitals.valence,
      'energy': vitals.energy,
      // The keeper's compatibility closeness is not the phone DB's v2 tier.
      'closeness': 0.0,
    });
  }

  Future<void> open(WidgetTester tester, {void Function(CompanionMemoryOwner)? seed}) async {
    this.tester = tester;
    addTearDown(() => close(tester));
    Directory('${root.path}/pack/runtime').createSync(recursive: true);
    Directory('${root.path}/pack/character').createSync(recursive: true);
    File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
    File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeHostProvider.overrideWith(_Host.new),
          activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: true))),
          settingsProvider.overrideWith(_Settings.new),
          companionLightClientProvider.overrideWithValue(newClient),
          companionPhoneKeeperProvider.overrideWithValue((directory) {
            phoneDirectory = directory;
            return phone;
          }),
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
    memory = await settleMixed(tester, container.read(companionMemoryOwnerProvider(root.absolute.path).future));
    await tester.pump();
    await settleMixed(tester, memory.migrateLocal());
    seed?.call(memory);
    await flush(tester);
    expect(container.read(companionSessionsProvider.notifier).of(HostRef.local)?.sessionId, _session);
    events!.onReady();
    await settleMixed(tester, phone.readStarted.future);
    await flush(tester);
    expect(phone.reads, 1);
    expect(phone.initialRead.isCompleted, isFalse);
    final directory = phoneDirectory!;
    expect(directory.parent.path, '${root.path}/activity');
    final role = directory.uri.pathSegments.where((part) => part.isNotEmpty).last;
    expect(memory.store.companionCharacter(role)?['source_key'], startsWith('local:'));
    commands.clear();
  }

  bool closed = false;

  Future<void> close(WidgetTester tester) async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox());
    phone.release();
    await tester.pump();
    bridge.release();
    final read = client.projectionRead;
    if (read != null && !read.isCompleted) read.complete(SessionProjections.empty);
    await tester.pump();
    await tester.runAsync(() async {
      for (final reply in replies) {
        if (!reply.isClosed) await reply.close();
      }
      // Nothing in the room watches the Host chat any more: a close of an
      // unlistened controller would wait for a listener forever.
      unawaited(client.events.close());
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
      room.phone.release();
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
      room.phone.release();
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
      room.phone.release();
      await flush(tester);
      final afterRead = room.speech(tester);
      room.expectVisitAndVitals();
      await tester.pump(const Duration(milliseconds: 1700));
      await tester.pump();
      debugPrint(
        '[C442 SNACK] ${jsonEncode({'afterRead': afterRead, 'afterTimer': room.speech(tester), 'phoneEvents': room.phone.writes.map((write) => write.$2).toList()})}',
      );
      expect(room.speech(tester), isIn([l10n.companionSnack1, l10n.companionSnack2, l10n.companionSnack3]));
      expect(afterRead, isNull);
      expect(room.commands.where((command) => command.$1 == 'say'), hasLength(1));
    } finally {
      await room.close(tester);
    }
  });

  // The send is accepted and its model request is out; no words have come
  // back yet. (The Host session read this once waited on is gone: the room's
  // chat is the phone loop in full mode too.)
  testWidgets('an accepted send awaiting her first words already supersedes the greeting', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    try {
      await room.send('稍等这一句');
      expect(room.running, isTrue);
      room.phone.release();
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
      await room.send('说一句。');
      expect(room.running, isTrue);
      expect(room.speech(tester), isNull);
      // The turn ends without a word.
      await room.finish();
      expect(room.running, isFalse);
      expect(find.text(room.l10n(tester).companionSendFailed), findsNothing);
      expect(find.text(room.l10n(tester).companionAgentRetryClosed), findsNothing);
      expect(room.speech(tester), isNull);
      room.phone.release();
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
      await room.send('说一句。');
      room.words('[表情:担心]');
      await room.finish();
      expect(room.running, isFalse);
      expect(room.memory.store.messages().where((row) => row['role'] == 'assistant').map((row) => row['text']), [
        '[表情:担心]',
      ]);
      expect(room.speech(tester), isNull);
      room.phone.release();
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
    final room = _Room(temporary);
    await room.open(
      tester,
      seed: (memory) {
        for (final (id, role, text) in [('old-user', 'user', '说一句。'), ('old-her', 'assistant', '[表情:开心]以前说过。')]) {
          memory.store.submitMessage(
            id: id,
            sessionId: memory.store.lightSessionId,
            role: role,
            text: text,
            saidAtUtc: _now,
            offsetMinutes: 0,
          );
        }
      },
    );
    try {
      expect(room.running, isFalse);
      expect(room.memory.store.messages().where((row) => row['role'] == 'assistant').single['text'], '[表情:开心]以前说过。');
      expect(room.speech(tester), isNull);
      // The process-level agent repeats its unchanged idle state to the window.
      room.container.read(companionAgentProvider).changed();
      await flush(tester);
      room.phone.release();
      await flush(tester);
      room.expectVisitAndVitals();
      // This pack has no name: she introduces herself without one.
      expect(room.speech(tester), room.l10n(tester).companionGreetFirstNameless);
      expect(room.commands.where((command) => command.$1 == 'emotion').map((command) => command.$2['name']), ['shy']);
      expect(room.asked, isEmpty);
    } finally {
      await room.close(tester);
    }
  });
}
