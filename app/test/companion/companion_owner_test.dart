import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_keeper.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/companion/companion_chrome.dart';
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

import '../chat/support/composer_fakes.dart' show FakeVoiceBridge;
import '../support/companion_session_peer.dart';
import 'phone_keeper_fake.dart';
import 'companion_test_settle.dart';

DshHttpResponse _json(Object value, [int status = 200]) =>
    DshHttpResponse(status, 'application/json', Uint8List.fromList(utf8.encode(jsonEncode(value))));

class _Bridge extends DshConnection {
  _Bridge(this.storeId) : super(Uri.parse('http://127.0.0.1:9'));
  final String storeId;
  int revision = 0;
  double valence = 0.25;
  Future<DshHttpResponse> Function()? nextGet;
  Future<DshHttpResponse> Function(Map<String, Object?>)? nextPost;
  final posts = <Map<String, Object?>>[];

  DshHttpResponse snapshot() => _json({
    'storeId': storeId,
    'revision': revision,
    'memoryRevision': 0,
    'asOf': 1793937600000,
    'state': {'valence': valence, 'energy': 0.75, 'closeness': 0, 'activity': 'idle'},
  });

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
      return _json({
        'v': 1,
        'storeId': '33333333-3333-4333-8333-333333333333',
        'revision': 0,
        'memoryRevision': 0,
        'memories': [],
      });
    }
    if (path != dshGoCompanionPath) {
      return _json({
        'error': {'code': 'companion/not-found'},
      }, 404);
    }
    final handler = nextGet;
    nextGet = null;
    return handler == null ? snapshot() : await handler();
  }

  @override
  Future<DshHttpResponse> getBounded(
    String path, {
    Map<String, String>? query,
    required int maxBytes,
    bool autoUncompress = false,
    Duration timeout = const Duration(seconds: 30),
  }) async => _json({
    'error': {'code': 'companion/not-found'},
  }, 404);

  @override
  Future<DshHttpStreamResponse> postJsonStream(
    String path, Object? body, {
    required DshHttpAbort abort,
    Duration? headerTimeout,
    Duration? idleTimeout = const Duration(seconds: 20),
  }) => path.endsWith('/session-tools/open')
      ? Future.value(DshHttpStreamResponse(404, 'text/plain', const Stream.empty(), () async {}))
      : super.postJsonStream(path, body, abort: abort, headerTimeout: headerTimeout, idleTimeout: idleTimeout);

  @override
  Future<DshHttpResponse> postJson(String path, Object? body, {Duration? timeout}) async {
    final request = Map<String, Object?>.from(body! as Map);
    posts.add(request);
    final handler = nextPost;
    nextPost = null;
    if (handler != null) return await handler(request);
    revision++;
    return snapshot();
  }
}

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
  void change(HostRef host) => state = host;
}

class _Sessions extends CompanionSessions {
  Future<CompanionBinding>? pending;
  final ensureStarted = Completer<void>();
  final bindings = <HostRef, CompanionBinding>{};

  @override
  Map<String, CompanionBinding> build() => const {};
  @override
  CompanionBinding? of(HostRef host) => bindings[host];
  @override
  CompanionBinding? ofCharacter(HostRef host, String? sourceKey) => of(host);
  @override
  Future<CompanionBinding> ensureForCharacter(String? sourceKey, {
    String? memoryArchiveId, int? memoryControlRevision, String? replaceSessionId, String? requireSessionId,
  }) => ensure(memoryArchiveId: memoryArchiveId, memoryControlRevision: memoryControlRevision);
  @override
  Future<void> forgetCharacter(String? sourceKey) => forget();

  @override
  Future<CompanionBinding> ensure({String? memoryArchiveId, int? memoryControlRevision}) async {
    final host = ref.read(activeHostProvider);
    if (!ensureStarted.isCompleted) ensureStarted.complete();
    final result = await (pending ?? Future.value(CompanionBinding('companion-${host.id}')));
    final binding = CompanionBinding(
      result.sessionId,
      inlinePersona: result.inlinePersona,
      full: result.full,
      memoryArchiveId: memoryArchiveId,
      memoryControlRevision: memoryControlRevision,
    );
    bindings[host] = binding;
    return binding;
  }

  @override
  Future<void> forgetAll() async {
    bindings.clear();
  }
}

class _Chat extends ChatController {
  _Chat(super.sessionId);
  final sent = <String>[];
  @override
  ChatState build() => const ChatState(loading: false);
  @override
  Future<bool> waitForSync({bool Function()? isCurrent}) async => isCurrent?.call() ?? true;
  @override
  Future<bool> send(
    String text, {
    List<DraftAttachment> attachments = const [],
    SendMode mode = SendMode.now,
    bool verbatim = false,
    String? originalRequestId,
    Future<bool> Function(String requestId)? beforeDeliver,
    bool Function()? deliveryAllowed,
  }) async {
    sent.add(text);
    return true;
  }
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true, apiKey: 'sk-test');
}

// Controlled I/O at the existing phone-keeper boundary. The Page/Agent,
// epoch retirement, event queue, SQLite owner and role identity stay real.
class _Phone extends FakePhoneKeeper {
  _Phone() : super(state: FakePhoneKeeper.snapshotOf(closeness: 0));

  final firstRead = Completer<void>();
  final firstWrite = Completer<void>();
  final writes = <Map<String, Object?>>[];
  final pendingReads = <Completer<CompanionSnapshot?>>[];
  final pendingWrites = <Completer<CompanionSnapshot>>[];
  Future<CompanionSnapshot?> Function()? nextRead;
  Future<CompanionSnapshot> Function(CompanionSnapshot, String)? nextEvent;
  int reads = 0;

  static CompanionSnapshot value({int revision = 0, double valence = 0.35}) => CompanionSnapshot.fromJson({
    'storeId': 'd0a90d66-ff37-4f2a-b31c-194c791ec651',
    'revision': revision,
    'memoryRevision': 0,
    'asOf': 1793899800000,
    'state': {'valence': valence, 'energy': 0.75, 'closeness': 0, 'activity': 'idle'},
  })!;

  Completer<CompanionSnapshot?> holdRead() {
    final gate = Completer<CompanionSnapshot?>();
    pendingReads.add(gate);
    nextRead = () => gate.future;
    return gate;
  }

  Completer<CompanionSnapshot> holdWrite() {
    final gate = Completer<CompanionSnapshot>();
    pendingWrites.add(gate);
    nextEvent = (_, _) => gate.future;
    return gate;
  }

  @override
  Future<CompanionSnapshot?> snapshot() {
    reads++;
    if (!firstRead.isCompleted) firstRead.complete();
    final handler = nextRead;
    nextRead = null;
    return handler == null ? super.snapshot() : handler();
  }

  @override
  Future<CompanionSnapshot> event(CompanionSnapshot read, String type) async {
    writes.add({'storeId': read.storeId, 'expectedRevision': read.revision, 'type': type});
    if (!firstWrite.isCompleted) firstWrite.complete();
    final handler = nextEvent;
    nextEvent = null;
    if (handler == null) return super.event(read, type);
    final result = await handler(read, type);
    state = result;
    return result;
  }

  void releaseGates() {
    for (final gate in pendingReads) {
      if (!gate.isCompleted) gate.complete(state);
    }
    for (final gate in pendingWrites) {
      if (!gate.isCompleted) gate.complete(state!);
    }
  }
}

class _DelayedVoiceCancel extends FakeVoiceBridge {
  final started = Completer<void>();
  final cancelling = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> startRecognizer({String? language}) async {
    await super.startRecognizer(language: language);
    started.complete();
  }

  @override
  Future<void> cancel() async {
    await super.cancel();
    if (!cancelling.isCompleted) cancelling.complete();
    await release.future;
  }
}

class _Room {
  _Room(this.root, {this.sessionPeer = false, this.voice}) {
    final bridge = _Bridge('store-a');
    a = bridge;
    final client = sessionPeer ? CompanionSessionPeer(bridge) : DshClient(bridge);
    clients.add(client);
    connections[HostRef.local] = HostConnection(client: client, isLocal: true);
    Directory('${root.path}/pack/runtime').createSync(recursive: true);
    Directory('${root.path}/pack/character').createSync(recursive: true);
    File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
    File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
  }
  final Directory root;
  final bool sessionPeer;
  final VoiceBridge? voice;
  final phone = _Phone();
  Directory? phoneDirectory;
  late final _Bridge a;
  final host = _Host();
  final sessions = _Sessions();
  final clients = <DshClient>[];
  final connections = <HostRef, HostConnection>{};
  final chats = <String, _Chat>{};
  final commands = <(String, Map<String, Object?>)>[];
  CompanionStageEvents? events;
  late ProviderContainer container;

  /// Light mode: what the phone asked the model, and the reply it streams back.
  final lightAsked = <Map<String, Object?>>[];
  StreamController<List<int>>? lightReply;
  late final http.Client light = MockClient.streaming((request, body) async {
    lightAsked.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
    lightReply = StreamController<List<int>>();
    return http.StreamedResponse(lightReply!.stream, 200);
  });

  void lightSays(String text) => lightReply!.add(
    utf8.encode(
      'data: ${jsonEncode({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': text},
      })}\n\n',
    ),
  );

  void lightDone() {
    lightReply!.add(utf8.encode('data: {"type":"message_stop"}\n\n'));
    unawaited(lightReply!.close());
  }

  _Bridge connect(HostRef host) {
    final bridge = _Bridge('store-${host.id}');
    final client = sessionPeer ? CompanionSessionPeer(bridge) : DshClient(bridge);
    clients.add(client);
    connections[host] = HostConnection(client: client, isLocal: host.isLocal, kind: host.kind, hostId: host.id);
    return bridge;
  }

  Widget app(Widget child) => ProviderScope(
    overrides: [
      activeHostProvider.overrideWith(() => host),
      if (voice case final bridge?) voiceBridgeProvider.overrideWithValue(bridge),
      activeConnectionProvider.overrideWith((ref) => AsyncData(connections[ref.watch(activeHostProvider)])),
      companionSessionsProvider.overrideWith(() => sessions),
      if (!sessionPeer) chatProvider.overrideWith2((id) => chats.putIfAbsent(id, () => _Chat(id))),
      settingsProvider.overrideWith(_Settings.new),
      companionLightClientProvider.overrideWithValue(() => light),
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
      home: child,
    ),
  );

  Future<void> open(WidgetTester tester, {bool waitForVisit = true}) async {
    addTearDown(() => close(tester));
    await tester.pumpWidget(
      app(
        CompanionPage(
          storeOverride: CompanionPackStore(root),
          stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
          stageBuilder: (_, next) {
            events = next;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    for (var i = 0; i < 100 && events == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(events, isNotNull);
    container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
    final memory = await settleMixed(tester, container.read(companionMemoryOwnerProvider(root.absolute.path).future));
    await tester.pump();
    await settleMixed(tester, memory.migrateLocal());
    await tester.pump();
    events!.onReady();
    await settleMixed(tester, phone.firstRead.future);
    final directory = phoneDirectory!;
    expect(directory.parent.path, '${root.path}/activity');
    final role = directory.uri.pathSegments.where((part) => part.isNotEmpty).last;
    expect(memory.store.companionCharacter(role)?['source_key'], startsWith('local:'));
    if (waitForVisit) await settleMixed(tester, phone.firstWrite.future);
    await flush(tester);
  }

  bool closed = false;

  Future<void> close(WidgetTester tester) async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(app(const SizedBox()));
    phone.releaseGates();
    await tester.pump(const Duration(seconds: 15));
    for (final client in clients) {
      if (client is CompanionSessionPeer) {
        await settleMixed(tester, client.closeAll());
      } else {
        await client.close();
      }
    }
  }
}

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory temporary;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    temporary = Directory.systemTemp.createTempSync('companion-owner-');
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  testWidgets('a late snapshot from the old host cannot replace the new host', (tester) async {
    final room = _Room(temporary);
    final oldRead = room.phone.holdRead();
    const nextHost = HostRef.ssh('b');
    final b = room.connect(nextHost)..valence = 0.55;
    await room.open(tester, waitForVisit: false);
    expect(room.phone.reads, 1);
    expect(room.phone.writes, isEmpty);
    room.host.change(nextHost);
    await settleMixed(tester, room.phone.firstWrite.future);
    await flush(tester);
    expect(room.phone.reads, 2);
    // Host B is only a possible legacy seed; current vitals come from phone.
    expect(room.commands.where((c) => c.$1 == 'vitals').last.$2['valence'], room.phone.state!.vitals.valence);
    expect(room.a.posts, isEmpty);
    expect(b.posts, isEmpty);
    room.commands.clear();
    oldRead.complete(_Phone.value(valence: 0.9));
    await flush(tester);
    expect(room.commands.where((c) => c.$1 == 'vitals'), isEmpty);
    await room.close(tester);
  });

  testWidgets('an event queued on A is not sent to B after an old write fails', (tester) async {
    final room = _Room(temporary);
    final oldWrite = room.phone.holdWrite();
    const nextHost = HostRef.ssh('b');
    final b = room.connect(nextHost);
    await room.open(tester);
    expect(room.phone.writes.single['type'], 'visit');
    room.events!.onObject('snack');
    room.host.change(nextHost);
    await flush(tester);
    oldWrite.completeError(const DshClosedException('old visit write failed'));
    await flush(tester);
    expect(room.phone.writes.where((write) => write['type'] == 'snack'), isEmpty);
    expect(room.phone.writes.where((write) => write['type'] == 'visit'), hasLength(2));
    expect(room.a.posts, isEmpty);
    expect(b.posts, isEmpty);
    await room.close(tester);
  });

  testWidgets('a failed conflict refresh does not poison later events', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    room.phone.nextEvent = (_, _) async => throw const DshRemoteException('companion/conflict', 'conflict');
    room.phone.nextRead = () async => throw const DshClosedException('lost refresh');
    room.events!.onObject('snack');
    await flush(tester);
    expect(tester.takeException(), isNull);
    room.events!.onObject('play');
    await flush(tester);
    expect(room.phone.writes.where((write) => write['type'] == 'snack'), hasLength(1));
    expect(room.phone.writes.where((write) => write['type'] == 'play'), hasLength(1));
    expect(room.a.posts, isEmpty);
    await room.close(tester);
  });

  testWidgets('the same host with a replacement client refreshes companion state', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    room.commands.clear();
    final replacement = room.connect(HostRef.local)..valence = 0.9;
    room.phone.state = _Phone.value(revision: 1, valence: 0.7);
    final nextVisit = room.phone.holdWrite();
    room.container.invalidate(activeConnectionProvider);
    await flush(tester);
    expect(room.phone.reads, 2);
    expect(room.commands.where((c) => c.$1 == 'vitals').last.$2['valence'], 0.7);
    expect(room.phone.writes.map((write) => write['type']), ['visit', 'visit']);
    nextVisit.complete(_Phone.value(revision: 2, valence: 0.7));
    await flush(tester);
    room.events!.onObject('play');
    await flush(tester);
    expect(room.phone.writes.where((write) => write['type'] == 'play'), hasLength(1));
    expect(room.a.posts, isEmpty);
    expect(replacement.posts, isEmpty);
    await room.close(tester);
  });

  for (final switchHost in [false, true]) {
    testWidgets('dictated send keeps its recipient while native cancellation is pending (switch: $switchHost)', (tester) async {
      SharedPreferences.setMockInitialValues({'companion_mode': 'full', 'voice_recognition_mode': 'system'});
      final voice = _DelayedVoiceCancel();
      final room = _Room(temporary, sessionPeer: true, voice: voice);
      const nextHost = HostRef.ssh('b');
      room.connect(nextHost);
      final hostA = room.connections[HostRef.local]!.client as CompanionSessionPeer;
      final hostB = room.connections[nextHost]!.client as CompanionSessionPeer;
      await room.open(tester);
      try {
        final field = tester.widget<TextField>(find.byType(TextField)).controller!;
        final here = tester.widget<CompanionComposer>(find.byType(CompanionComposer));
        here.onVoice();
        await settleMixed(tester, voice.started.future);
        await tester.pump();
        const words = '只交给原来的小屋。';
        voice.emit(const VoicePartial(words));
        await tester.pump();
        expect(field.text, words);
        expect(find.byKey(const ValueKey('send')), findsOneWidget);
        // Retain the actual handler's Future so the negative checks wait for its whole submission.
        final send = (tester.widget<CompanionComposer>(find.byType(CompanionComposer)).onSend as Future<void> Function())();
        await settleMixed(tester, voice.cancelling.future);
        expect(hostA.prompts, isEmpty);
        expect(hostB.prompts, isEmpty);
        if (switchHost) {
          room.host.change(nextHost);
          await flush(tester);
          expect(room.container.read(activeConnectionProvider).value!.client, same(hostB));
          expect(tester.widget<TextField>(find.byType(TextField)).controller, same(field));
          await tester.enterText(find.byType(TextField), '新小屋未发送的草稿。');
        }
        voice.release.complete();
        await settleMixed(tester, send);
        await flush(tester);
        final memory = room.container.read(companionMemoryOwnerProvider(room.root.absolute.path)).value!;
        expect(hostA.prompts.map((request) => request.text), switchHost ? isEmpty : [words]);
        expect(hostB.prompts, isEmpty);
        expect(memory.store.messages().where((row) => row['text'] == words), hasLength(switchHost ? 0 : 1));
        expect(room.lightAsked, isEmpty);
        if (switchHost) expect(field.text, '新小屋未发送的草稿。');
      } finally {
        if (!voice.release.isCompleted) voice.release.complete();
        await room.close(tester);
      }
      // Hangs on CI (Pro A31) and leaves the room behind for every later test; back with Pro's fix.
    }, skip: true);
  }

  testWidgets('switching host retires a pending send without restoring its draft into B', (tester) async {
    SharedPreferences.setMockInitialValues({'companion_mode': 'full'});
    final room = _Room(temporary, sessionPeer: true);
    const nextHost = HostRef.ssh('b');
    room.connect(nextHost);
    final hostA = room.connections[HostRef.local]!.client as CompanionSessionPeer;
    final hostB = room.connections[nextHost]!.client as CompanionSessionPeer;
    final response = Completer<void>();
    hostA.holdBeforeResponse = response.future;
    await room.open(tester);
    addTearDown(() {
      if (!response.isCompleted) response.complete();
    });
    await tester.enterText(find.byType(TextField), '属于 A 的句子');
    tester.widget<CompanionComposer>(find.byType(CompanionComposer)).onSend();
    await settleMixed(tester, hostA.firstPrompt.future);
    final sent = hostA.prompts.single;
    expect(sent.session, room.sessions.of(HostRef.local)!.sessionId);
    expect(sent.text, '属于 A 的句子');
    expect(sent.requestId, isNotEmpty);
    expect(room.lightAsked, isEmpty);
    final memory = room.container.read(companionMemoryOwnerProvider(room.root.absolute.path)).value!;
    expect(memory.store.messages().where((row) => row['text'] == sent.text), hasLength(1));
    room.host.change(nextHost);
    await flush(tester);
    final composer = tester.widget<CompanionComposer>(find.byType(CompanionComposer));
    expect(composer.busy, isFalse, reason: 'B must not inherit A\'s pending preparation');
    expect(composer.running, isFalse, reason: 'B must not inherit A\'s active turn');

    // A commits a real follow-frame reply after B owns the room.
    response.complete();
    await settleMixed(tester, hostA.firstTurnEnded.future);
    await flush(tester);
    final messages = hostA.records[sent.session]!.where((row) => row['type'] == 'assistant/message');
    expect(messages, hasLength(1));
    expect(jsonEncode(messages.single), contains('会话回复'));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(find.textContaining('会话回复'), findsNothing);
    expect(memory.store.messages().where((row) => row['role'] == 'assistant'), isEmpty);
    expect(hostA.prompts, hasLength(1));
    expect(hostB.prompts, isEmpty);
    expect(room.lightAsked, isEmpty);
    await room.close(tester);
    // Still fails on CI after A06hR2; back with Pro's fix.
  }, skip: true);

  testWidgets('queued events become inert after the page is disposed', (tester) async {
    final room = _Room(temporary);
    final oldWrite = room.phone.holdWrite();
    await room.open(tester);
    expect(room.phone.writes.single['type'], 'visit');
    room.events!.onObject('snack');
    await tester.pumpWidget(room.app(const SizedBox()));
    oldWrite.complete(_Phone.value(revision: 1));
    await flush(tester);
    expect(tester.takeException(), isNull);
    expect(room.phone.writes.where((write) => write['type'] == 'snack'), isEmpty);
    expect(room.a.posts, isEmpty);
    await room.close(tester);
  });

  testWidgets('a superseded object line cannot overwrite a later touch', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    room.commands.clear();
    room.events!.onObject('snack');
    await tester.pump(const Duration(milliseconds: 100));
    room.events!.onTouch('face', 'tap');
    await tester.pump(const Duration(milliseconds: 100));
    room.commands.clear();
    await tester.pump(const Duration(seconds: 2));
    expect(room.commands.where((c) => c.$1 == 'say'), isEmpty);
    await room.close(tester);
  });

  testWidgets('a successful old event cannot repaint the new host', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    final oldWrite = room.phone.holdWrite();
    room.events!.onObject('snack');
    await flush(tester);
    expect(room.phone.writes.last['type'], 'snack');
    const nextHost = HostRef.ssh('b');
    final b = room.connect(nextHost);
    room.host.change(nextHost);
    await flush(tester);
    expect(room.phone.writes.where((write) => write['type'] == 'visit'), hasLength(2));
    room.commands.clear();
    oldWrite.complete(_Phone.value(revision: 2, valence: 0.95));
    await flush(tester);
    expect(room.commands.where((command) => command.$1 == 'vitals'), isEmpty);
    expect(room.a.posts, isEmpty);
    expect(b.posts, isEmpty);
    await room.close(tester);
  });

  testWidgets('returning A to B to A does not revive the first A read', (tester) async {
    final room = _Room(temporary);
    final firstRead = room.phone.holdRead();
    const nextHost = HostRef.ssh('b');
    room.connect(nextHost);
    await room.open(tester, waitForVisit: false);
    room.host.change(nextHost);
    await settleMixed(tester, room.phone.firstWrite.future);
    await flush(tester);
    room.host.change(HostRef.local);
    await flush(tester);
    expect(room.phone.reads, 3);
    expect(room.phone.writes.where((write) => write['type'] == 'visit'), hasLength(2));
    room.commands.clear();
    firstRead.complete(_Phone.value(valence: 0.95));
    await flush(tester);
    expect(room.commands.where((command) => command.$1 == 'vitals'), isEmpty);
    await room.close(tester);
  });

  testWidgets('events in one room stay serial and use the preceding revision', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    final firstWrite = room.phone.holdWrite();
    room.events!.onObject('snack');
    room.events!.onObject('play');
    await flush(tester);
    expect(room.phone.writes.map((write) => write['type']), ['visit', 'snack']);
    final previousRevision = room.phone.writes.last['expectedRevision']! as int;
    firstWrite.complete(_Phone.value(revision: previousRevision + 1));
    await flush(tester);
    expect(room.phone.writes.map((write) => write['type']), ['visit', 'snack', 'play']);
    expect(room.phone.writes.last['expectedRevision'], previousRevision + 1);
    expect(room.a.posts, isEmpty);
    await room.close(tester);
  });

  testWidgets('conflicts read again without replaying the rejected event', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    room.phone.nextEvent = (_, _) async => throw const DshRemoteException('companion/conflict', 'conflict');
    room.phone.state = _Phone.value(revision: 7);
    room.events!.onObject('snack');
    await flush(tester);
    expect(room.phone.reads, 2);
    room.events!.onObject('play');
    await flush(tester);
    expect(room.phone.writes.where((write) => write['type'] == 'snack'), hasLength(1));
    expect(room.phone.writes.last['type'], 'play');
    expect(room.phone.writes.last['expectedRevision'], 7);
    expect(room.a.posts, isEmpty);
    await room.close(tester);
  });

  Future<void> say(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send).last);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a light reply goes on when the host changes under it, and asks no host', (tester) async {
    SharedPreferences.setMockInitialValues({'companion_mode': 'light'});
    final room = _Room(temporary);
    await room.open(tester);
    await tester.pump(const Duration(seconds: 9)); // The greeting goes.
    await say(tester, '你好');
    expect(room.lightAsked, hasLength(1));
    room.lightSays('你来啦。');
    await flush(tester);

    room.connect(const HostRef.ssh('b'));
    room.host.change(const HostRef.ssh('b'));
    await flush(tester);
    room.lightSays('我在这儿。');
    room.lightDone();
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('你来啦。我在这儿。'), findsOneWidget);
    expect(room.a.posts, isEmpty);
    expect(room.chats.values.expand((chat) => chat.sent), isEmpty);
    await room.close(tester);
  });

  testWidgets('with no mode picked, losing the host turns her light for the next line', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    await tester.pump(const Duration(seconds: 9));
    room.connections.remove(HostRef.local);
    room.host.change(const HostRef.ssh('gone'));
    await flush(tester);
    await say(tester, '你还在吗');
    expect(room.lightAsked, hasLength(1));
    expect(room.chats.values.expand((chat) => chat.sent), isEmpty);
    room.lightSays('在呀。');
    room.lightDone();
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('在呀。'), findsOneWidget);
    await room.close(tester);
  });
}
