// Real drawer UI with in-memory hosts and a fake deletion backend only.
// Never connects to or deletes a user's sessions.
import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/image_snapshots.dart';
import 'package:dsh_app/state/session_deletion_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/shell/drawer/selection_bars.dart';
import 'package:dsh_app/ui/shell/drawer/session_deletion.dart';
import 'package:dsh_app/ui/shell/drawer/session_tile.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../drawer/support.dart';
import '../shell/golden_harness.dart';
import '../workspace/support.dart';
import 'read_list_refresh_test.dart' show SwitchConnection, switchConnectionProvider;

class _NoSnapshots extends ImageSnapshots {
  @override
  Future<void> removeSession(String host, String sessionId) async {}
}

class _DeletionBackend implements SessionDeletionBackend {
  final hosts = <DshClient, DrawerHost>{};
  final calls = <({DshClient client, String id})>[];
  final failures = <String, String>{};
  bool available = true;
  Object? supportError;
  Completer<bool>? supportReply;
  Completer<void>? firstDeleteReply;

  @override
  Future<bool> supported(DshClient client) async {
    if (supportError case final error?) throw error;
    if (supportReply != null) return supportReply!.future;
    return available;
  }

  @override
  Future<void> delete(DshClient client, String sessionId) async {
    calls.add((client: client, id: sessionId));
    if (calls.length == 1 && firstDeleteReply != null) await firstDeleteReply!.future;
    final code = failures[sessionId];
    if (code == 'connection-lost') throw const DshClosedException('controlled fake transport loss');
    if (code == 'protocol-error') throw const DshProtocolException('controlled fake protocol error');
    if (code != null) throw DshRemoteException(code, 'controlled fake rejection');
    final host = hosts[client]!;
    // Only a test fixture list is modified, not a file or real backend.
    host.sessions.removeWhere((row) => row['sessionId'] == sessionId);
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 450));
}

DrawerHost _host(String name) {
  final host = DrawerHost();
  final now = DateTime(2026, 10, 28, 10);
  host.seedSession('s1', '$name first', now);
  host.seedSession('s2', '$name second', now.subtract(const Duration(seconds: 1)));
  host.seedSession('running', '$name running', now.subtract(const Duration(seconds: 2)), running: true);
  host.seedWorkspace('/root/$name', sessionIds: ['s1', 's2', 'running']);
  return host;
}

Future<({DrawerHost host, HostConnection connection, ProviderContainer container, _DeletionBackend backend})> _start(
  WidgetTester tester, {
  _DeletionBackend? backend,
  bool showChat = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final host = _host('A');
  final connection = workspaceHost(host);
  addTearDown(connection.client.close);
  final fake = backend ?? _DeletionBackend();
  fake.hosts[connection.client] = host;
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      home: HomeShell(chatBuilder: showChat ? null : (_) => const SizedBox.expand(), initiallyOpen: true),
      overrides: [
        ...workspaceOverrides(host, current: 's1', prefs: const WorkspacePrefs(loaded: true)).skip(1),
        switchConnectionProvider.overrideWith(() => SwitchConnection(connection)),
        activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
        sessionDeletionBackendProvider.overrideWithValue(fake),
        imageSnapshotsProvider.overrideWithValue(_NoSnapshots()),
      ],
    ),
  );
  await _settle(tester);
  final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
  return (host: host, connection: connection, container: container, backend: fake);
}

Finder _tile(String title) => find.widgetWithText(SessionTile, title);
Finder get _deleteAction => find.byKey(const ValueKey('session-delete-action'));
Finder get _confirmation => find.byKey(const ValueKey('session-delete-confirmation'));
Finder get _confirm => find.byKey(const ValueKey('session-delete-confirm'));

Future<void> _singleConfirmation(WidgetTester tester) async {
  await tester.longPress(_tile('A first'));
  await _settle(tester);
  await tester.ensureVisible(_deleteAction);
  await tester.tap(_deleteAction);
  await _settle(tester);
  expect(_confirmation, findsOneWidget);
}

Future<void> _bulkConfirmation(WidgetTester tester, ProviderContainer container) async {
  container.read(drawerSelectionProvider.notifier).start('s1');
  container.read(drawerSelectionProvider.notifier).toggle('s2');
  await _settle(tester);
  await tester.tap(find.descendant(of: find.byType(SelectionActionBar), matching: find.text('删除')));
  await _settle(tester);
  expect(_confirmation, findsOneWidget);
}

Future<HostConnection> _switchToB(WidgetTester tester, ProviderContainer container, _DeletionBackend backend) async {
  final host = _host('B');
  final connection = workspaceHost(host, local: false);
  addTearDown(connection.client.close);
  backend.hosts[connection.client] = host;
  container.read(switchConnectionProvider.notifier).set(connection);
  container.read(activeHostProvider.notifier).select(HostRef.ssh('pc'));
  await _settle(tester);
  return connection;
}

void main() {
  testWidgets('long press keeps archive, names chat, warns about retained data, and cancel sends nothing', (
    tester,
  ) async {
    final fixture = await _start(tester);
    await tester.longPress(_tile('A first'));
    await _settle(tester);
    expect(find.text('归档'), findsOneWidget);
    await tester.ensureVisible(_deleteAction);
    await tester.tap(_deleteAction);
    await _settle(tester);
    expect(find.text('永久删除「A first」？'), findsOneWidget);
    expect(find.textContaining('无法撤销'), findsOneWidget);
    expect(find.textContaining('工作目录、生成的文件、分叉对话、共享附件和已发布的云端分享都会保留'), findsOneWidget);
    await tester.tap(find.descendant(of: _confirmation, matching: find.text('取消')));
    await _settle(tester);
    expect(fixture.backend.calls, isEmpty);
    expect(fixture.host.argsOf('workspace/archiveSession'), isEmpty);
    expect(_tile('A first'), findsOneWidget);
  });

  testWidgets('confirmed single deletion removes only acknowledged row, never archives', (tester) async {
    final fixture = await _start(tester);
    await _singleConfirmation(tester);
    expect(fixture.backend.calls, isEmpty);
    await tester.tap(_confirm);
    await _settle(tester);
    expect(fixture.backend.calls.map((call) => call.id), ['s1']);
    expect(_tile('A first'), findsNothing);
    expect(_tile('A second'), findsOneWidget);
    expect(fixture.container.read(currentSessionProvider), isNull);
    expect(fixture.host.argsOf('workspace/archiveSession'), isEmpty);
    expect(find.text('已永久删除 1 个对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deletion receipt leaves the real composer visible and tappable after closing the drawer', (
    tester,
  ) async {
    await _start(tester, showChat: true);
    await _singleConfirmation(tester);
    await tester.tap(_confirm);
    await _settle(tester);
    expect(find.text('已永久删除 1 个对话'), findsOneWidget);

    // The drawer's scrim closes it while the receipt is still on screen.
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(size.width - 20, size.height / 2));
    await _settle(tester);
    final input = find.descendant(of: find.byType(Composer), matching: find.byType(EditableText));
    expect(input, findsOneWidget);
    final receipt = find.text('已永久删除 1 个对话');
    final receiptCard = find.ancestor(of: receipt, matching: find.byType(Material)).first;
    expect(tester.getRect(receiptCard).bottom, lessThan(tester.getRect(input).top));
    await tester.tap(input);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<EditableText>(input).focusNode.hasFocus, isTrue);
    await tester.enterText(input, '继续输入');
    expect(tester.widget<EditableText>(input).controller.text, '继续输入');

    tester.view.viewInsets = FakeViewPadding(bottom: 300 * tester.view.devicePixelRatio);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('已永久删除 1 个对话'), findsOneWidget);
    expect(tester.getRect(receiptCard).bottom, lessThan(tester.getRect(input).top));
    expect(tester.widget<EditableText>(input).focusNode.hasFocus, isTrue);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MaterialBanner), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deletion receipt can be dismissed without dismissing the conversation', (tester) async {
    await _start(tester);
    await _singleConfirmation(tester);
    await tester.tap(_confirm);
    await _settle(tester);
    await tester.tap(find.descendant(of: find.byType(MaterialBanner), matching: find.text('关闭')));
    await _settle(tester);
    expect(find.byType(MaterialBanner), findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a retired deletion receipt cannot dismiss the next banner', (tester) async {
    await _start(tester);
    await _singleConfirmation(tester);
    await tester.tap(_confirm);
    await _settle(tester);
    final messenger = ScaffoldMessenger.of(tester.element(find.byType(HomeShell)));
    messenger.removeCurrentMaterialBanner();
    messenger.showMaterialBanner(
      MaterialBanner(
        content: const Text('Another notice'),
        actions: [TextButton(onPressed: () {}, child: const Text('OK'))],
      ),
    );
    await _settle(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Another notice'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported host explains disabled delete without archive fallback', (tester) async {
    final fixture = await _start(tester, backend: _DeletionBackend()..available = false);
    await tester.longPress(_tile('A first'));
    await _settle(tester);
    await tester.ensureVisible(_deleteAction);
    final tile = tester.widget<ListTile>(_deleteAction);
    expect(tile.enabled, isFalse);
    expect(tile.onTap, isNull);
    expect(find.text('此主机不支持安全永久删除，仍可使用归档。'), findsOneWidget);
    expect(find.text('归档'), findsOneWidget);
    expect(fixture.backend.calls, isEmpty);
    expect(fixture.host.argsOf('workspace/archiveSession'), isEmpty);
  });

  testWidgets('capability probe errors show unavailable and never archive instead', (tester) async {
    final backend = _DeletionBackend()..supportError = const DshClosedException('controlled fake failure');
    final fixture = await _start(tester, backend: backend);
    await tester.longPress(_tile('A first'));
    await _settle(tester);
    await tester.ensureVisible(_deleteAction);
    expect(tester.widget<ListTile>(_deleteAction).onTap, isNull);
    expect(find.text('安全永久删除暂不可用，请重连或更新此主机；不会改为归档。'), findsOneWidget);
    expect(backend.calls, isEmpty);
    expect(fixture.host.argsOf('workspace/archiveSession'), isEmpty);
  });

  testWidgets('capability loading disables deletion until safe support is confirmed', (tester) async {
    final gate = Completer<bool>();
    final fixture = await _start(tester, backend: _DeletionBackend()..supportReply = gate);
    await tester.longPress(_tile('A first'));
    await _settle(tester);
    await tester.ensureVisible(_deleteAction);
    expect(tester.widget<ListTile>(_deleteAction).onTap, isNull);
    expect(find.text('正在检查此主机是否支持永久删除…'), findsOneWidget);
    gate.complete(true);
    await _settle(tester);
    expect(tester.widget<ListTile>(_deleteAction).onTap, isNotNull);
    expect(fixture.backend.calls, isEmpty);
  });

  testWidgets('capability states map to three different explanations, never a false refusal', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    String? reason(SessionDeletionSupport support, {List<String> ids = const ['s1']}) =>
        sessionDeletionDisabledReason(
          context,
          available: AsyncData(support),
          busy: false,
          sessions: const [],
          ids: ids,
        );
    // Not asked yet (no live connection / no ready mux generation) is a
    // "temporarily unavailable", never "this host does not support it".
    expect(reason(SessionDeletionSupport.unknown), '安全永久删除暂不可用，请重连或更新此主机；不会改为归档。');
    expect(reason(SessionDeletionSupport.unsupported), '此主机不支持安全永久删除，仍可使用归档。');
    expect(reason(SessionDeletionSupport.supported, ids: const []), isNull);
  });

  testWidgets('running single and mixed bulk selection cannot request deletion', (tester) async {
    final fixture = await _start(tester);
    await tester.longPress(_tile('A running'));
    await _settle(tester);
    await tester.ensureVisible(_deleteAction);
    expect(tester.widget<ListTile>(_deleteAction).onTap, isNull);
    expect(find.textContaining('请先停止运行中的工作'), findsOneWidget);
    await tester.tapAt(const Offset(380, 100));
    await _settle(tester);
    fixture.container.read(drawerSelectionProvider.notifier).start('s1');
    fixture.container.read(drawerSelectionProvider.notifier).toggle('running');
    await _settle(tester);
    final label = find.descendant(of: find.byType(SelectionActionBar), matching: find.text('删除'));
    final ink = find.ancestor(of: label, matching: find.byType(InkWell)).first;
    expect(tester.widget<InkWell>(ink).onTap, isNull);
    expect(fixture.backend.calls, isEmpty);
  });

  testWidgets('bulk count confirmation reports exact partial failures and keeps failed rows', (tester) async {
    final backend = _DeletionBackend()..failures['s2'] = 'writer-held';
    final fixture = await _start(tester, backend: backend);
    await _bulkConfirmation(tester, fixture.container);
    expect(find.text('永久删除 2 个对话？'), findsOneWidget);
    await tester.tap(_confirm);
    await _settle(tester);
    expect(backend.calls.map((call) => call.id), ['s1', 's2']);
    expect(_tile('A first'), findsNothing);
    expect(_tile('A second'), findsOneWidget);
    expect(fixture.container.read(drawerSelectionProvider), {'s2'});
    expect(find.text('已删除 1 个，失败 1 个'), findsOneWidget);
    expect(find.textContaining('A second\ns2\n'), findsOneWidget);
    expect(find.textContaining('(writer-held)'), findsOneWidget);
    expect(fixture.host.argsOf('workspace/archiveSession'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all failures retain rows and report each exact stable reason', (tester) async {
    final backend = _DeletionBackend()
      ..failures['s1'] = 'session-active'
      ..failures['s2'] = 'session-related';
    final fixture = await _start(tester, backend: backend);
    await _bulkConfirmation(tester, fixture.container);
    await tester.tap(_confirm);
    await _settle(tester);
    expect(_tile('A first'), findsOneWidget);
    expect(_tile('A second'), findsOneWidget);
    expect(fixture.container.read(drawerSelectionProvider), {'s1', 's2'});
    expect(find.text('已删除 0 个，失败 2 个'), findsOneWidget);
    expect(find.textContaining('A first\ns1\n'), findsOneWidget);
    expect(find.textContaining('(session-active)'), findsOneWidget);
    expect(find.textContaining('A second\ns2\n'), findsOneWidget);
    expect(find.textContaining('(session-related)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unconfirmed deletion stops batch and marks remaining IDs not attempted', (tester) async {
    final backend = _DeletionBackend()..failures['s1'] = 'connection-lost';
    final fixture = await _start(tester, backend: backend);
    await _bulkConfirmation(tester, fixture.container);
    await tester.tap(_confirm);
    await _settle(tester);
    expect(backend.calls.map((call) => call.id), ['s1']);
    expect(_tile('A first'), findsOneWidget);
    expect(_tile('A second'), findsOneWidget);
    expect(find.textContaining('(connection-lost)'), findsOneWidget);
    expect(find.textContaining('(not-attempted)'), findsOneWidget);
    expect(find.textContaining('删除结果未确认，请刷新对话列表后再操作'), findsOneWidget);
    expect(fixture.container.read(drawerSelectionProvider), {'s1', 's2'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('a replacement selection cannot inherit an old bulk confirmation', (tester) async {
    final fixture = await _start(tester);
    await _bulkConfirmation(tester, fixture.container);
    fixture.container.read(drawerSelectionProvider.notifier).start('s1');
    fixture.container.read(drawerSelectionProvider.notifier).toggle('s2');
    final newer = fixture.container.read(drawerSelectionProvider);
    await tester.tap(_confirm);
    await _settle(tester);
    expect(fixture.backend.calls, isEmpty);
    expect(fixture.container.read(drawerSelectionProvider), same(newer));
    expect(tester.takeException(), isNull);
  });

  testWidgets('held batch shows progress and leaves rows until acknowledgement', (tester) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final backend = _DeletionBackend()..firstDeleteReply = gate;
    final fixture = await _start(tester, backend: backend);
    await _bulkConfirmation(tester, fixture.container);
    await tester.tap(_confirm);
    await _settle(tester);
    expect(find.byKey(const ValueKey('session-delete-progress')), findsOneWidget);
    expect(fixture.container.read(sessionDeletionBusyProvider), isTrue);
    expect(_tile('A first'), findsOneWidget);
    expect(backend.calls, hasLength(1));
    gate.complete();
    await _settle(tester);
    expect(find.byKey(const ValueKey('session-delete-progress')), findsNothing);
    expect(fixture.container.read(drawerSelectionProvider), isNull);
    expect(find.text('已永久删除 2 个对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final stage in ['action sheet', 'confirmation']) {
    testWidgets('A to B to A permanently retires old $stage consent', (tester) async {
      final fixture = await _start(tester);
      await tester.longPress(_tile('A first'));
      await _settle(tester);
      await tester.ensureVisible(_deleteAction);
      if (stage == 'confirmation') {
        await tester.tap(_deleteAction);
        await _settle(tester);
      }
      await _switchToB(tester, fixture.container, fixture.backend);
      fixture.container.read(switchConnectionProvider.notifier).set(fixture.connection);
      fixture.container.read(activeHostProvider.notifier).select(HostRef.local);
      await _settle(tester);
      if (stage == 'confirmation') {
        expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
      } else {
        expect(tester.widget<ListTile>(_deleteAction).onTap, isNull);
      }
      expect(find.text('主机或连接已变化。请取消后重新发起删除，原确认不再有效。'), findsOneWidget);
      expect(fixture.backend.calls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a same-client mux reconnect keeps the open confirmation valid', (tester) async {
    final fixture = await _start(tester);
    await _singleConfirmation(tester);
    final ready = fixture.connection.client.mux.lastReadyGenerationNumber;
    fixture.connection.client.mux.reconnect();
    await _settle(tester);
    expect(fixture.connection.client.mux.lastReadyGenerationNumber, greaterThan(ready));
    // Deleting is one HTTP request, not an event-stream operation: the same
    // client reconnected to the same host is still the same authority, so the
    // confirmation is not thrown away (nor shown as "the host changed").
    expect(find.text('主机或连接已变化。请取消后重新发起删除，原确认不再有效。'), findsNothing);
    await _settle(tester);
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNotNull);
    expect(fixture.backend.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('host switch while delete is held stops remaining batch and suppresses late UI', (tester) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final backend = _DeletionBackend()..firstDeleteReply = gate;
    final fixture = await _start(tester, backend: backend);
    await _bulkConfirmation(tester, fixture.container);
    await tester.tap(_confirm);
    await _settle(tester);
    expect(backend.calls, hasLength(1));
    final b = await _switchToB(tester, fixture.container, backend);
    fixture.container.read(drawerSelectionProvider.notifier).start('s1');
    final newer = fixture.container.read(drawerSelectionProvider);
    gate.complete();
    await _settle(tester);
    expect(backend.calls, hasLength(1));
    expect(backend.calls.where((call) => identical(call.client, b.client)), isEmpty);
    expect(fixture.container.read(drawerSelectionProvider), same(newer));
    expect(_tile('B first'), findsOneWidget);
    expect(find.byKey(const ValueKey('session-delete-failures')), findsNothing);
    expect(find.text('已永久删除 2 个对话'), findsNothing);
    expect(find.byKey(const ValueKey('session-delete-progress')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
