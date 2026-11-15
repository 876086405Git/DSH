// Automatic recall (Pro C902) in her room, full mode: switched on with a plain
// confirmation into a new clean conversation, shown on only when the host says
// ready; switched off by revoking and letting the bound conversation go; and a
// binding retired meanwhile (her memories changed) is found when the room binds.
// The host is a scripted bridge; the page, sessions owner and chat are real.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _store = '33333333-3333-4333-8333-333333333333';
const _epoch = '44444444-4444-4444-8444-444444444444';
const _binding = '22222222-2222-4222-8222-222222222222';
const _other = '55555555-5555-4555-8555-555555555555';
const _title = '完整模式里自动想起记忆';

class _Bridge extends DshConnection {
  _Bridge() : super(Uri.parse('http://127.0.0.1:9'));

  bool supported = true;
  String? active;
  String bindStatus = 'ready';
  String status = 'ready';
  final binds = <Map<String, Object?>>[];
  final revokes = <Map<String, Object?>>[];
  final statusReads = <String>[];

  DshHttpResponse _json(Object value, {int code = 200}) =>
      DshHttpResponse(code, 'application/json', Uint8List.fromList(utf8.encode(jsonEncode(value))));

  Map<String, Object?> _record(String id, String state, String session, {int memoryRevision = 3}) => {
    'v': 1,
    'bindingId': id,
    'bridgeEpoch': _epoch,
    'recallEpoch': 1,
    'storeId': _store,
    'memoryRevision': memoryRevision,
    'sessionId': session,
    'status': state,
    'reason': state == 'ready' ? null : 'memory-changed',
    'selectorVersion': companionRecallSelector,
    'serverNow': 1794090000000,
  };

  @override
  Future<DshHttpResponse> get(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
    int? maxResponseBytes,
  }) async => _json({
    'storeId': _store,
    'revision': 0,
    'memoryRevision': 3,
    'asOf': 1793937600000,
    'state': {'valence': 0.25, 'energy': 0.75, 'closeness': 0, 'activity': 'idle'},
  });

  @override
  Future<DshHttpResponse> postJson(String path, Object? body, {Duration? timeout}) => get(path);

  @override
  Future<DshHttpResponse> getBounded(
    String path, {
    Map<String, String>? query,
    required int maxBytes,
    bool autoUncompress = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (path == '/dsh-go/v1/companion/recall') {
      return _json({
        'v': 1,
        'supported': supported,
        'reason': supported ? null : 'provider-unverified',
        'busy': active != null,
        'activeBindingId': active,
        'selectorVersion': companionRecallSelector,
        'maxItems': 12,
        'textUtf16Budget': 1200,
      });
    }
    const prefix = '/dsh-go/v1/companion/recall/bindings/';
    if (path.startsWith(prefix)) {
      final id = path.substring(prefix.length);
      statusReads.add(id);
      return _json(_record(id, status, 'bound'));
    }
    return _json({
      'error': {'code': 'companion/not-found'},
    }, code: 404);
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
  }) async {
    final body = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    if (path == '/dsh-go/v1/companion/recall/bind') {
      binds.add(body);
      if (bindStatus == 'ready') active = _binding;
      return _json(
        _record(
          _binding,
          bindStatus,
          body['sessionId']! as String,
          memoryRevision: body['expectedMemoryRevision']! as int,
        ),
      );
    }
    if (path == '/dsh-go/v1/companion/recall/revoke') {
      revokes.add(body);
      active = null;
      return _json(_record(body['bindingId']! as String, 'retired', 'bound'));
    }
    return _json({
      'error': {'code': 'companion/not-found'},
    }, code: 404);
  }
}

class _Mux extends DshMux {
  _Mux(super.carrier);
  final connection = StreamController<DshConnectionState>.broadcast();
  @override
  Stream<DshConnectionState> get states => connection.stream;
}

class _Client extends DshClient {
  _Client(this.bridge) : super(bridge);
  final _Bridge bridge;
  late final _fakeMux = _Mux(carrier);
  final _watches = <StreamController<DshEvent>>[];
  final watched = <String>[];
  @override
  _Mux get mux => _fakeMux;

  /// Every conversation is there and empty: a snapshot as soon as it is followed.
  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) {
    final controller = StreamController<DshEvent>();
    _watches.add(controller);
    watched.add(sessionId);
    controller.onListen = () => controller.add(
      parseFollowFrame(sessionId, {
        'type': 'snapshot',
        'cursor': -1,
        'records': [],
        'assistantStream': {'revision': 0},
      }),
    );
    return controller.stream;
  }

  Future<void> closeAll() async {
    for (final watch in _watches) {
      await watch.close();
    }
    await _fakeMux.connection.close();
    await close();
  }
}

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

/// Her conversations without a host to create them on: new ones are numbered.
class _Sessions extends CompanionSessions {
  int created = 0;
  int forgotten = 0;
  String _key(HostRef host) => '${host.kind.name}:${host.id}';

  @override
  Future<CompanionBinding> ensure() async {
    final host = ref.read(activeHostProvider);
    final known = of(host);
    if (known != null) return known;
    final binding = CompanionBinding('fresh-${++created}');
    state = {...state, _key(host): binding};
    return binding;
  }

  @override
  Future<void> forget() async {
    forgotten++;
    state = {...state}..remove(_key(ref.read(activeHostProvider)));
  }
}

class _Room {
  _Room(this.root);
  final Directory root;
  final bridge = _Bridge();
  late final client = _Client(bridge);
  late final sessions = _Sessions();
  final commands = <(String, Map<String, Object?>)>[];
  CompanionStageEvents? events;

  Future<void> open(WidgetTester tester, {bool waitOutGreeting = true}) async {
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
      await settle(tester);
    }
    expect(events, isNotNull, reason: 'the stage was never built');
    final container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
    // Her stored conversation is known before the stage is ready, as in the app.
    container.read(companionSessionsProvider);
    await settle(tester);
    events!.onReady();
    await settle(tester);
    if (!waitOutGreeting) return;
    await tester.pump(const Duration(seconds: 8)); // The greeting goes.
    await settle(tester);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The recall row in her menu, once the host has answered.
  Future<Switch> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(AppIcons.more));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.text(_title), findsOneWidget);
    final row = find.ancestor(of: find.text(_title), matching: find.byType(MergeSemantics)).first;
    return tester.widget<Switch>(find.descendant(of: row, matching: find.byType(Switch)));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    await tester.runAsync(client.closeAll);
  }
}

Future<Map<String, Object?>> _stored() async {
  final raw = (await SharedPreferences.getInstance()).getString('companion_recall_bindings');
  return raw == null ? {} : jsonDecode(raw) as Map<String, Object?>;
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('companion-recall-room');
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a file a moment longer; the system clears temp.
    }
  });

  void prefs({Map<String, Object?>? recall}) => SharedPreferences.setMockInitialValues({
    'companion_touch_hint_done': true,
    'companion_home_hint_done': true,
    'companion_sessions': jsonEncode({
      'local:${HostRef.local.id}': {'id': recall == null ? 'old' : 'bound', 'full': true},
    }),
    'companion_recall_bindings': ?(recall == null ? null : jsonEncode(recall)),
  });

  testWidgets('on: said plainly, a new clean conversation, bound, and on only once the host says ready', (
    tester,
  ) async {
    prefs();
    final room = _Room(root);
    await room.open(tester);
    try {
      expect((await room.openMenu(tester)).value, isFalse);
      await tester.tap(find.text(_title));
      await tester.pumpAndSettle();
      // What goes along, and what happens to the conversation, before anything does.
      expect(find.textContaining('最多 12 条'), findsOneWidget);
      expect(find.textContaining('主对话列表'), findsOneWidget);
      expect(room.sessions.forgotten, 0);
      await tester.tap(find.widgetWithText(FilledButton, '打开'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        await room.settle(tester);
      }

      expect(room.sessions.forgotten, 1);
      expect(room.sessions.created, 1);
      // The room talks to the new conversation now.
      expect(room.client.watched.last, 'fresh-1');
      expect(room.sessions.of(HostRef.local)?.sessionId, 'fresh-1');
      final bind = room.bridge.binds.single;
      expect(bind['sessionId'], 'fresh-1');
      expect(bind['storeId'], _store);
      expect(bind['expectedMemoryRevision'], 3);
      expect(bind['consent'], companionRecallSelector);
      final prefs = await SharedPreferences.getInstance();
      expect(bind['consumerId'], prefs.getString('companion_recall_consumer'));
      expect(await _stored(), {
        'local:${HostRef.local.id}': {'binding': _binding, 'session': 'fresh-1'},
      });
      expect(find.text('好，从这段新对话起，我会想着你让我记住的事。'), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
      expect((await room.openMenu(tester)).value, isTrue);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('a bind that does not come back ready is not shown on, and nothing is kept', (tester) async {
    prefs();
    final room = _Room(root);
    room.bridge.bindStatus = 'unavailable';
    await room.open(tester);
    try {
      await room.openMenu(tester);
      await tester.tap(find.text(_title));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '打开'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        await room.settle(tester);
      }
      expect(room.bridge.binds, hasLength(1));
      expect(await _stored(), isEmpty);
      expect(find.text('自动想起记忆没打开，再试一次吧'), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      expect((await room.openMenu(tester)).value, isFalse);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('another conversation has it: she says so and takes nothing over', (tester) async {
    prefs();
    final room = _Room(root);
    room.bridge.active = _other;
    await room.open(tester);
    try {
      await room.openMenu(tester);
      await tester.tap(find.text(_title));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '打开'));
      await tester.pumpAndSettle();
      await room.settle(tester);
      expect(find.text('另一个对话正在用自动想起记忆，先在那边关掉再来'), findsOneWidget);
      expect(room.sessions.forgotten, 0);
      expect(room.bridge.binds, isEmpty);
      expect(room.bridge.revokes, isEmpty);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('off: the host retires it, and the bound conversation is let go', (tester) async {
    prefs(
      recall: {
        'local:${HostRef.local.id}': {'binding': _binding, 'session': 'bound'},
      },
    );
    final room = _Room(root);
    await room.open(tester);
    try {
      expect(room.bridge.statusReads, [_binding]);
      expect((await room.openMenu(tester)).value, isTrue);
      await tester.tap(find.text(_title));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await room.settle(tester);
      }
      expect(room.bridge.revokes.single['bindingId'], _binding);
      expect(room.sessions.forgotten, 1);
      // The next line opens a new ordinary conversation.
      expect(room.sessions.of(HostRef.local), isNull);
      expect(await _stored(), isEmpty);
      expect(find.text('自动想起记忆关了，下一句会开始一段新对话'), findsOneWidget);
    } finally {
      await room.close(tester);
    }
  });

  testWidgets('retired meanwhile (her memories changed): found on binding, let go, told once', (tester) async {
    prefs(
      recall: {
        'local:${HostRef.local.id}': {'binding': _binding, 'session': 'bound'},
      },
    );
    final room = _Room(root);
    room.bridge.status = 'retired';
    await room.open(tester, waitOutGreeting: false);
    try {
      expect(room.bridge.statusReads, [_binding]);
      expect(room.sessions.forgotten, 1);
      expect(await _stored(), isEmpty);
      expect(find.textContaining('自动想起记忆停了'), findsOneWidget);
      expect(room.bridge.revokes, isEmpty);
      await tester.pump(const Duration(seconds: 9));
      expect(find.textContaining('自动想起记忆停了'), findsNothing);
      expect((await room.openMenu(tester)).value, isFalse);
      expect(room.bridge.statusReads, [_binding]);
    } finally {
      await room.close(tester);
    }
  });
}
