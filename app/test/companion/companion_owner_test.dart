import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_keeper.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
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

import 'phone_keeper_fake.dart';

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
    final handler = nextGet;
    nextGet = null;
    return handler == null ? snapshot() : await handler();
  }

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
  final bindings = <HostRef, CompanionBinding>{};

  @override
  Map<String, CompanionBinding> build() => const {};
  @override
  CompanionBinding? of(HostRef host) => bindings[host];
  @override
  Future<CompanionBinding> ensure() async {
    final host = ref.read(activeHostProvider);
    return await (pending ?? Future.value(CompanionBinding('companion-${host.id}')));
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

class _Room {
  _Room(this.root) {
    final bridge = _Bridge('store-a');
    a = bridge;
    final client = DshClient(bridge);
    clients.add(client);
    connections[HostRef.local] = HostConnection(client: client, isLocal: true);
    Directory('${root.path}/pack/runtime').createSync(recursive: true);
    Directory('${root.path}/pack/character').createSync(recursive: true);
    File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
    File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
  }
  final Directory root;
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
    final client = DshClient(bridge);
    clients.add(client);
    connections[host] = HostConnection(client: client, isLocal: host.isLocal, kind: host.kind, hostId: host.id);
    return bridge;
  }

  Widget app(Widget child) => ProviderScope(
    overrides: [
      activeHostProvider.overrideWith(() => host),
      activeConnectionProvider.overrideWith((ref) => AsyncData(connections[ref.watch(activeHostProvider)])),
      companionSessionsProvider.overrideWith(() => sessions),
      chatProvider.overrideWith2((id) => chats.putIfAbsent(id, () => _Chat(id))),
      settingsProvider.overrideWith(_Settings.new),
      companionLightClientProvider.overrideWithValue(() => light),
      companionPhoneKeeperProvider.overrideWithValue((_) => FakePhoneKeeper()),
    ],
    child: MaterialApp(
      theme: buildDarkTheme(),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      locale: const Locale('zh'),
      home: child,
    ),
  );

  Future<void> open(WidgetTester tester) async {
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
    events!.onReady();
    await flush(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(app(const SizedBox()));
    await tester.pump(const Duration(seconds: 15));
    for (final client in clients) {
      await client.close();
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
    final oldRead = Completer<DshHttpResponse>();
    room.a.nextGet = () => oldRead.future;
    const nextHost = HostRef.ssh('b');
    final b = room.connect(nextHost)..valence = 0.55;
    await room.open(tester);
    room.host.change(nextHost);
    await flush(tester);
    expect(room.commands.where((c) => c.$1 == 'vitals').last.$2['valence'], b.valence);
    room.commands.clear();
    room.a.valence = 0.9;
    oldRead.complete(room.a.snapshot());
    await flush(tester);
    expect(room.commands.where((c) => c.$1 == 'vitals'), isEmpty);
    await room.close(tester);
  });

  testWidgets('an event queued on A is not sent to B after an old write fails', (tester) async {
    final room = _Room(temporary);
    final oldWrite = Completer<DshHttpResponse>();
    room.a.nextPost = (_) => oldWrite.future;
    const nextHost = HostRef.ssh('b');
    final b = room.connect(nextHost);
    await room.open(tester);
    expect(room.a.posts.single['type'], 'visit');
    room.events!.onObject('snack');
    room.host.change(nextHost);
    await flush(tester);
    oldWrite.completeError(const DshClosedException('old connection closed'));
    await flush(tester);
    expect(b.posts.where((post) => post['type'] == 'snack'), isEmpty);
    expect(b.posts.where((post) => post['type'] == 'visit'), hasLength(1));
    await room.close(tester);
  });

  testWidgets('a failed conflict refresh does not poison later events', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    room.a.nextPost = (_) async => _json({
      'error': {'code': 'companion/conflict'},
    }, 409);
    room.a.nextGet = () async => throw const DshClosedException('lost refresh');
    room.events!.onObject('snack');
    await flush(tester);
    expect(tester.takeException(), isNull);
    room.events!.onObject('play');
    await flush(tester);
    expect(room.a.posts.where((post) => post['type'] == 'play'), hasLength(1));
    await room.close(tester);
  });

  testWidgets('the same host with a replacement client refreshes companion state', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    room.commands.clear();
    final replacement = room.connect(HostRef.local)..valence = 0.7;
    room.container.invalidate(activeConnectionProvider);
    await flush(tester);
    expect(room.commands.where((c) => c.$1 == 'vitals').last.$2['valence'], replacement.valence);
    room.events!.onObject('play');
    await flush(tester);
    expect(replacement.posts.where((post) => post['type'] == 'play'), hasLength(1));
    await room.close(tester);
  });

  testWidgets('switching host retires a pending send without restoring its draft into B', (tester) async {
    final room = _Room(temporary);
    final pending = Completer<CompanionBinding>();
    room.sessions.pending = pending.future;
    const nextHost = HostRef.ssh('b');
    room.connect(nextHost);
    await room.open(tester);
    await tester.enterText(find.byType(TextField), '属于 A 的句子');
    tester.widget<CompanionComposer>(find.byType(CompanionComposer)).onSend();
    await flush(tester);
    room.host.change(nextHost);
    await flush(tester);
    final busyAfterSwitch = tester.widget<CompanionComposer>(find.byType(CompanionComposer)).busy;
    pending.complete(const CompanionBinding('companion-local'));
    await flush(tester);
    expect((busyAfterSwitch, tester.widget<TextField>(find.byType(TextField)).controller!.text), (false, ''));
    expect(room.chats.values.expand((chat) => chat.sent), isEmpty);
    await room.close(tester);
  });

  testWidgets('queued events become inert after the page is disposed', (tester) async {
    final room = _Room(temporary);
    final oldWrite = Completer<DshHttpResponse>();
    room.a.nextPost = (_) => oldWrite.future;
    await room.open(tester);
    room.events!.onObject('snack');
    await tester.pumpWidget(room.app(const SizedBox()));
    oldWrite.complete(room.a.snapshot());
    await flush(tester);
    expect(tester.takeException(), isNull);
    expect(room.a.posts.where((post) => post['type'] == 'snack'), isEmpty);
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
    final oldWrite = Completer<DshHttpResponse>();
    room.a.nextPost = (_) => oldWrite.future;
    room.events!.onObject('snack');
    await flush(tester);
    const nextHost = HostRef.ssh('b');
    room.connect(nextHost);
    room.host.change(nextHost);
    await flush(tester);
    room.commands.clear();
    room.a.valence = 0.95;
    oldWrite.complete(room.a.snapshot());
    await flush(tester);
    expect(room.commands.where((command) => command.$1 == 'vitals'), isEmpty);
    await room.close(tester);
  });

  testWidgets('returning A to B to A does not revive the first A read', (tester) async {
    final room = _Room(temporary);
    final firstRead = Completer<DshHttpResponse>();
    room.a.nextGet = () => firstRead.future;
    const nextHost = HostRef.ssh('b');
    room.connect(nextHost);
    await room.open(tester);
    room.host.change(nextHost);
    await flush(tester);
    room.host.change(HostRef.local);
    await flush(tester);
    room.commands.clear();
    room.a.valence = 0.95;
    firstRead.complete(room.a.snapshot());
    await flush(tester);
    expect(room.commands.where((command) => command.$1 == 'vitals'), isEmpty);
    await room.close(tester);
  });

  testWidgets('events in one room stay serial and use the preceding revision', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    final firstWrite = Completer<DshHttpResponse>();
    room.a.nextPost = (_) => firstWrite.future;
    room.events!.onObject('snack');
    room.events!.onObject('play');
    await flush(tester);
    expect(room.a.posts.map((post) => post['type']), ['visit', 'snack']);
    final previousRevision = room.a.posts.last['expectedRevision']! as int;
    room.a.revision++;
    firstWrite.complete(room.a.snapshot());
    await flush(tester);
    expect(room.a.posts.map((post) => post['type']), ['visit', 'snack', 'play']);
    expect(room.a.posts.last['expectedRevision'], previousRevision + 1);
    await room.close(tester);
  });

  testWidgets('conflicts read again without replaying the rejected event', (tester) async {
    final room = _Room(temporary);
    await room.open(tester);
    room.a.nextPost = (_) async => _json({
      'error': {'code': 'companion/conflict'},
    }, 409);
    room.a.revision = 7;
    room.events!.onObject('snack');
    await flush(tester);
    room.events!.onObject('play');
    await flush(tester);
    expect(room.a.posts.where((post) => post['type'] == 'snack'), hasLength(1));
    expect(room.a.posts.last['type'], 'play');
    expect(room.a.posts.last['expectedRevision'], 7);
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
