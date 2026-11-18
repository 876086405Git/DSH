// The real memory page and CompanionApi codecs; only the HTTP boundary is
// controlled so normal host changes can complete requests in either order.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/companion/companion_memory_page.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

DshHttpResponse _json(Object value, [int status = 200]) =>
    DshHttpResponse(status, 'application/json', Uint8List.fromList(utf8.encode(jsonEncode(value))));

const _memoryId = '11111111-1111-4111-8111-111111111111';

class _Bridge extends DshConnection {
  _Bridge(this.store, this.text) : super(Uri.parse('http://127.0.0.1:9'));
  final String store;
  String? text;
  Map<String, Object?> source = const {'kind': 'manual'};
  int? expiresAt;
  int revision = 0;
  int snapshotReads = 0;
  int listReads = 0;
  Future<DshHttpResponse> Function()? nextSnapshot;
  Future<DshHttpResponse> Function()? nextList;
  Future<DshHttpResponse> Function()? nextWrite;
  final writes = <(String, Map<String, Object?>)>[];

  DshHttpResponse snapshot() => _json({
    'storeId': store,
    'revision': 0,
    'memoryRevision': revision,
    'capabilities': {'memories': true},
    'state': {'activity': 'idle'},
  });

  DshHttpResponse memories() => _json({
    'storeId': store,
    'revision': revision,
    'memories': [
      if (text != null)
        {
          'id': _memoryId,
          'text': text,
          'kind': 'preference',
          'keywords': ['kept'],
          'pinned': true,
          'source': source,
          'expiresAt': expiresAt,
        },
    ],
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
      listReads++;
      final handler = nextList;
      nextList = null;
      return handler == null ? memories() : await handler();
    }
    expect(path, dshGoCompanionPath);
    snapshotReads++;
    final handler = nextSnapshot;
    nextSnapshot = null;
    return handler == null ? snapshot() : await handler();
  }

  @override
  Future<DshHttpResponse> postJson(String path, Object? body, {Duration? timeout}) async {
    final request = Map<String, Object?>.from(body! as Map);
    writes.add((path, request));
    final handler = nextWrite;
    nextWrite = null;
    if (handler != null) return await handler();
    if (path.endsWith('/delete')) {
      text = null;
    } else {
      text = (request['memory']! as Map)['text'] as String;
    }
    revision++;
    return _json({'revision': revision});
  }
}

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
  void change(HostRef host) => state = host;
}

class _Room {
  _Room() {
    a = connect(HostRef.local, 'A memory');
    addTearDown(() async {
      for (final client in clients) {
        await client.close();
      }
    });
  }
  late final _Bridge a;
  final host = _Host();
  final clients = <DshClient>[];
  final connections = <HostRef, HostConnection>{};
  late ProviderContainer container;

  _Bridge connect(HostRef host, String text) {
    final bridge = _Bridge('store-${host.id}-${clients.length}', text);
    final client = DshClient(bridge);
    clients.add(client);
    connections[host] = HostConnection(client: client, isLocal: host.isLocal, kind: host.kind, hostId: host.id);
    return bridge;
  }

  Widget app(Widget child) => ProviderScope(
    overrides: [
      activeHostProvider.overrideWith(() => host),
      activeConnectionProvider.overrideWith((ref) => AsyncData(connections[ref.watch(activeHostProvider)])),
      hostNameProvider.overrideWith((ref, host) => host.isLocal ? 'A host' : 'B host'),
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
    await tester.pumpWidget(app(const CompanionMemoryPage()));
    container = ProviderScope.containerOf(tester.element(find.byType(CompanionMemoryPage)));
    await flush(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(app(const SizedBox()));
    await tester.pumpAndSettle();
  }
}

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Future<void> edit(WidgetTester tester, String oldText, String newText, {bool save = true}) async {
  await tester.tap(find.text(oldText));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), newText);
  if (save) {
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('switching host clears old entries while the new list is pending', (tester) async {
    final room = _Room();
    const next = HostRef.ssh('b');
    final b = room.connect(next, 'B memory');
    final list = Completer<DshHttpResponse>();
    b.nextList = () => list.future;
    await room.open(tester);
    expect(find.text('A memory'), findsOneWidget);
    room.host.change(next);
    await flush(tester);
    expect(find.textContaining('保存在B host上'), findsOneWidget);
    expect(find.text('A memory'), findsNothing);
    expect(b.listReads, 1);
    list.complete(b.memories());
    await flush(tester);
    expect(find.text('B memory'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('a late old list cannot replace the current host list', (tester) async {
    final room = _Room();
    final old = Completer<DshHttpResponse>();
    room.a.nextList = () => old.future;
    const next = HostRef.ssh('b');
    room.connect(next, 'B memory');
    await room.open(tester);
    room.host.change(next);
    await flush(tester);
    old.complete(room.a.memories());
    await flush(tester);
    expect(find.text('A memory'), findsNothing);
    expect(find.text('B memory'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('a retired capability read does not begin an old-host list read', (tester) async {
    final room = _Room();
    final old = Completer<DshHttpResponse>();
    room.a.nextSnapshot = () => old.future;
    const next = HostRef.ssh('b');
    room.connect(next, 'B memory');
    await room.open(tester);
    room.host.change(next);
    await flush(tester);
    old.complete(room.a.snapshot());
    await flush(tester);
    expect(room.a.listReads, 0);
    expect(find.text('B memory'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('replacing a client on the same host reloads its memory list', (tester) async {
    final room = _Room();
    await room.open(tester);
    final replacement = room.connect(HostRef.local, 'Replacement memory');
    // Publish the replacement, rather than only marking this lazy provider
    // invalid. The page must respond to the new value without a host change.
    expect(
      identical(
        room.container.refresh(activeConnectionProvider).value?.client,
        room.connections[HostRef.local]!.client,
      ),
      isTrue,
    );
    await flush(tester);
    expect(replacement.listReads, 1);
    expect(find.text('A memory'), findsNothing);
    expect(find.text('Replacement memory'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('an A to B to A visit does not revive the first A read', (tester) async {
    final room = _Room();
    final old = Completer<DshHttpResponse>();
    final oldList = room.a.memories();
    room.a.nextList = () => old.future;
    const next = HostRef.ssh('b');
    room.connect(next, 'B memory');
    await room.open(tester);
    room.host.change(next);
    await flush(tester);
    room.a.text = 'New A memory';
    room.host.change(HostRef.local);
    await flush(tester);
    old.complete(oldList);
    await flush(tester);
    expect(find.text('A memory'), findsNothing);
    expect(find.text('New A memory'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('an edit dialog opened on A cannot write after switching host', (tester) async {
    final room = _Room();
    const next = HostRef.ssh('b');
    final b = room.connect(next, 'B memory');
    await room.open(tester);
    await edit(tester, 'A memory', 'A changed', save: false);
    room.host.change(next);
    await flush(tester);
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(room.a.writes, isEmpty);
    expect(b.writes, isEmpty);
    await room.close(tester);
  });

  testWidgets('a delete confirmation opened on A cannot act after switching host', (tester) async {
    final room = _Room();
    const next = HostRef.ssh('b');
    final b = room.connect(next, 'B memory');
    await room.open(tester);
    await tester.tap(find.byTooltip('忘掉'));
    await tester.pumpAndSettle();
    room.host.change(next);
    await flush(tester);
    await tester.tap(find.widgetWithText(FilledButton, '忘掉'));
    await tester.pumpAndSettle();
    expect(room.a.writes, isEmpty);
    expect(b.writes, isEmpty);
    await room.close(tester);
  });

  testWidgets('a late A write does not refresh B or keep B controls busy', (tester) async {
    final room = _Room();
    final old = Completer<DshHttpResponse>();
    room.a.nextWrite = () => old.future;
    const next = HostRef.ssh('b');
    final b = room.connect(next, 'B memory');
    await room.open(tester);
    await edit(tester, 'A memory', 'A changed');
    expect(room.a.writes, hasLength(1));
    room.host.change(next);
    await flush(tester);
    expect(find.text('B memory'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '添加')).onPressed,
      isNotNull,
    );
    final readsBeforeOldCompletion = b.listReads;
    old.complete(_json({'revision': 1}));
    await flush(tester);
    expect(b.listReads, readsBeforeOldCompletion);
    await room.close(tester);
  });

  testWidgets('an old failed write cannot unlock or show errors over a new write', (tester) async {
    final room = _Room();
    final old = Completer<DshHttpResponse>();
    room.a.nextWrite = () => old.future;
    const next = HostRef.ssh('b');
    final b = room.connect(next, 'B memory');
    final current = Completer<DshHttpResponse>();
    b.nextWrite = () => current.future;
    await room.open(tester);
    await edit(tester, 'A memory', 'A changed');
    room.host.change(next);
    await flush(tester);
    await edit(tester, 'B memory', 'B changed');
    expect(b.writes, hasLength(1));
    old.completeError(const DshClosedException('A closed'));
    await flush(tester);
    expect(find.text('没保存上，再试一次吧'), findsNothing);
    expect(
      tester.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '添加')).onPressed,
      isNull,
    );
    current.complete(_json({'revision': 1}));
    await flush(tester);
    expect(
      tester.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '添加')).onPressed,
      isNotNull,
    );
    await room.close(tester);
  });

  testWidgets('late failure of an earlier retry cannot erase a newer successful list', (tester) async {
    final room = _Room();
    room.a.nextSnapshot = () async => throw const DshClosedException('initial read failed');
    await room.open(tester);
    final old = Completer<DshHttpResponse>();
    room.a.nextSnapshot = () => old.future;
    final retry = find.text('重试');
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await tester.tap(retry);
    await flush(tester);
    expect(find.text('A memory'), findsOneWidget);
    old.completeError(const DshClosedException('older retry failed'));
    await flush(tester);
    expect(find.text('A memory'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('same-owner edit and delete keep store revision and memory fields', (tester) async {
    final room = _Room();
    await room.open(tester);
    await edit(tester, 'A memory', 'A changed');
    expect(find.text('A changed'), findsOneWidget);
    final saved = room.a.writes.single.$2;
    expect(saved['storeId'], room.a.store);
    expect(saved['expectedRevision'], 0);
    expect(saved['memory'], {
      'id': _memoryId,
      'kind': 'preference',
      'text': 'A changed',
      'keywords': ['kept'],
      'pinned': true,
      'source': {'kind': 'manual'},
      'expiresAt': null,
    });
    await tester.tap(find.byTooltip('忘掉'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '忘掉'));
    await tester.pumpAndSettle();
    expect(room.a.writes.last.$2, {'storeId': room.a.store, 'expectedRevision': 1, 'id': _memoryId});
    expect(find.text('A changed'), findsNothing);
    await room.close(tester);
  });

  testWidgets('a same-owner conflict rereads the host without retrying the write', (tester) async {
    final room = _Room();
    room.a.nextWrite = () async {
      room.a.text = 'Changed elsewhere';
      return _json({
        'error': {'code': 'companion/conflict'},
      }, 409);
    };
    await room.open(tester);
    await edit(tester, 'A memory', 'A changed');
    expect(room.a.writes, hasLength(1));
    expect(find.text('Changed elsewhere'), findsOneWidget);
    expect(find.text('刚才另一处改过了，已经刷新'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('a write whose reply is lost rereads what the host kept', (tester) async {
    final room = _Room();
    room.a.nextWrite = () async {
      room.a.text = 'A changed';
      room.a.revision++;
      throw const DshClosedException('reply lost after the write landed');
    };
    await room.open(tester);
    final reads = room.a.listReads;
    await edit(tester, 'A memory', 'A changed');
    expect(room.a.writes, hasLength(1));
    expect(room.a.listReads, greaterThan(reads));
    expect(find.text('A changed'), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('a pending list can finish after the page is disposed', (tester) async {
    final room = _Room();
    final old = Completer<DshHttpResponse>();
    room.a.nextList = () => old.future;
    await room.open(tester);
    await room.close(tester);
    old.complete(room.a.memories());
    await flush(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('C435: editing preserves source and expiry from the real memory GET', (tester) async {
    final room = _Room();
    const source = {'kind': 'user-confirmed', 'sessionId': 'confirmed-session', 'messageId': 'confirmed-message'};
    final expiry = DateTime.utc(2030, 1, 1).millisecondsSinceEpoch;
    room.a
      ..source = source
      ..expiresAt = expiry;
    await room.open(tester);
    await edit(tester, 'A memory', 'Only the text changes');
    expect(room.a.writes, hasLength(1));
    expect(room.a.writes.single.$2, {
      'storeId': room.a.store,
      'expectedRevision': 0,
      'memory': {
        'id': _memoryId,
        'text': 'Only the text changes',
        'kind': 'preference',
        'keywords': ['kept'],
        'pinned': true,
        'source': source,
        'expiresAt': expiry,
      },
    });
    await room.close(tester);
  });

  testWidgets('C435: adding a memory keeps the manual source and null expiry', (tester) async {
    final room = _Room();
    room.a.text = null;
    await room.open(tester);
    await tester.tap(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '添加'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'A new manual memory');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(room.a.writes, hasLength(1));
    final request = room.a.writes.single.$2;
    expect(request['storeId'], room.a.store);
    expect(request['expectedRevision'], 0);
    final memory = request['memory']! as Map;
    expect(memory['source'], {'kind': 'manual'});
    expect(memory['expiresAt'], isNull);
    expect(memory['text'], 'A new manual memory');
    expect(memory['kind'], 'fact');
    expect(memory['keywords'], isEmpty);
    expect(memory['pinned'], isFalse);
    await room.close(tester);
  });

  testWidgets('C436: an empty list cannot open another editor while its first save is pending', (tester) async {
    final room = _Room();
    room.a.text = null;
    final pending = Completer<DshHttpResponse>();
    room.a.nextWrite = () => pending.future;
    await room.open(tester);
    try {
      final emptyAdd = find.widgetWithText(OutlinedButton, '添加');
      await tester.tap(emptyAdd);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'First memory');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(room.a.writes, hasLength(1));
      expect(
        tester.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '添加')).onPressed,
        isNull,
      );
      expect(tester.widget<OutlinedButton>(emptyAdd).onPressed, isNull);
      await tester.tap(emptyAdd);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(room.a.writes, hasLength(1));
      room.a
        ..text = 'First memory'
        ..revision = 1;
      pending.complete(_json({'revision': 1}));
      await flush(tester);
      expect(find.text('First memory'), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '添加')).onPressed,
        isNotNull,
      );
    } finally {
      await room.close(tester);
      if (!pending.isCompleted) pending.complete(_json({'revision': 1}));
    }
  });
}
