import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/relay/dsh_remote_backend.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/session_backup/backup_store.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/session_backup_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/remote/session_backup_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/dsh_remote.dart' as remote;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;

const _server = 'https://backup.example.invalid';
const _deviceId = 'original-device';
const _restoredId = 'known-restored-session';
const _backupTitle = 'Backup snapshot';
const _host = RelayHost(id: 'host-one', name: 'Backup Host', online: true, fingerprint: 'HOST FINGERPRINT');
const _peer = BackupPeer(
  server: _server,
  hostId: 'host-one',
  hostName: 'Backup Host',
  fingerprint: 'HOST FINGERPRINT',
  deviceId: _deviceId,
);
const _workspace = Workspace(
  workspaceId: 'target-workspace',
  path: '/workspace',
  title: 'Target workspace',
  sessionIds: [],
);

class _Active extends ActiveHostController {
  @override
  HostRef build() => const HostRef.relay('host-one');
}

class _Account extends remote.RemoteAccount {
  _Account() : super(secrets: remote.MemorySecretStore(), serverUrl: _server);

  String deviceId = _deviceId;

  @override
  Future<remote.RemoteUser?> currentUser() async =>
      remote.RemoteUser(account: 'backup-fixture', deviceId: deviceId, serverUrl: serverUrl);
}

class _RelayAccount extends RelayAccountController {
  _RelayAccount(this.deviceId);
  final String deviceId;

  @override
  Future<RelayAccountState> build() async => RelayAccountState(
    available: true,
    user: RelayUser(id: deviceId, displayName: 'Backup fixture'),
    hosts: const [_host],
  );
}

class _Workspaces extends WorkspacesController {
  @override
  WorkspacesState build() => const WorkspacesState(status: WorkspacesStatus.ready, workspaces: [_workspace]);
}

class _Sessions extends SessionsController {
  @override
  Future<List<SessionSummary>> build() async => const [];

  @override
  Future<void> refresh() async {}
}

class _Rpc implements remote.RemoteRpcClient {
  final calls = <(String, Map<String, Object?>)>[];
  Future<void> Function()? beforeResult;
  bool _closed = false;

  List<String> get methods => calls.map((entry) => entry.$1).toList();

  @override
  bool get isClosed => _closed;

  @override
  Future<Object?> call(String method, Object? params, {Duration? timeout}) async {
    final args = Map<String, Object?>.from(params! as Map);
    calls.add((method, args));
    switch (method) {
      case 'session.transfer.import.open':
        return {'handle': 'import-handle', 'chunkBytes': 256 * 1024, 'maxBytes': 8 * 1024 * 1024};
      case 'session.transfer.import.chunk':
        return {'receivedBytes': (args['offset']! as int) + base64Decode(args['data']! as String).length};
      case 'session.transfer.import.commit':
      case 'session.transfer.import.status':
        await beforeResult?.call();
        return {
          if (method.endsWith('.status')) 'status': 'completed',
          'sessionId': _restoredId,
          'workspaceAttached': false,
        };
      default:
        throw StateError('Unexpected RPC $method');
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Carrier implements remote.RemoteTunnelCarrier {
  _Carrier(this.session);

  @override
  remote.RemoteHostSession? session;

  @override
  Stream<remote.RemoteHostSession> get sessions => const Stream.empty();

  @override
  Stream<remote.RemoteConnectionState> get states => const Stream.empty();

  @override
  Future<void> close() async {
    await session?.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Finder _messageContaining(String text) =>
    find.byWidgetPredicate((widget) => widget is SelectableText && (widget.data?.contains(text) ?? false));

Future<void> _until(WidgetTester tester, bool Function() done, String reason) async {
  for (var i = 0; i < 300; i++) {
    if (done()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 5));
  }
  fail('Did not settle: $reason');
}

void main() {
  setUpAll(loadGoldenFonts);

  late Directory root;
  late MemorySecretStore secrets;
  late SessionBackupStore store;
  late SessionBackup backup;
  late BackupRestore pending;
  late _Account account;
  late _Rpc rpc;
  late _Carrier carrier;
  late DshClient client;
  late Locale previousLocale;

  setUp(() async {
    previousLocale = AppLocale.current;
    AppLocale.use(AppLocale.en);
    root = await Directory.systemTemp.createTemp('session-backup-page-');
    secrets = MemorySecretStore();
    store = await SessionBackupStore.open(root, secrets);
    final bytes = Uint8List.fromList(gzip.encode(utf8.encode('private snapshot')));
    final data = remote.SessionTransferData(
      gzipBytes: bytes,
      totalBytes: bytes.length,
      sha256: crypto.sha256.convert(bytes).toString(),
    );
    backup = SessionBackup(
      id: '00000000000000000000000000000001',
      source: _peer,
      workspaceId: 'source-workspace',
      sessionId: 'source-session',
      title: _backupTitle,
      throughSeq: 42,
      createdAt: DateTime.utc(2026, 11, 19),
      totalBytes: data.totalBytes,
      sha256: data.sha256,
    );
    await store.add(backup, data);
    pending = BackupRestore(
      backupId: backup.id,
      target: _peer,
      workspaceId: _workspace.workspaceId,
      batchId: 'original-batch',
      requestId: 'original-request',
    );
    account = _Account();
    rpc = _Rpc();
    carrier = _Carrier(remote.RemoteHostSession(rpc: rpc, capabilities: const ['session.transfer.import.v1']));
    client = DshClient.withCarrier(carrier);
  });

  tearDown(() async {
    await client.close();
    await rpc.close();
    await account.close();
    await root.delete(recursive: true);
    AppLocale.use(previousLocale);
  });

  Future<void> pump(WidgetTester tester, {String deviceId = _deviceId}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1800);
    addTearDown(tester.view.reset);
    account.deviceId = deviceId;
    final connection = HostConnection(client: client, isLocal: false, kind: HostKind.relay, hostId: _host.id);
    await tester.pumpWidget(
      goldenApp(
        home: const SessionBackupPage(),
        brightness: Brightness.light,
        overrides: [
          activeHostProvider.overrideWith(_Active.new),
          readListLiveConnectionProvider.overrideWithValue(connection),
          relayBackendProvider.overrideWithValue(DshRemoteRelayBackend(secrets: secrets, account: account)),
          relayAccountProvider.overrideWith(() => _RelayAccount(deviceId)),
          sessionsProvider.overrideWith(_Sessions.new),
          workspacesProvider.overrideWith(_Workspaces.new),
          sessionBackupStoreProvider.overrideWith((ref) async => store),
        ],
      ),
    );
    await _until(tester, () {
      final row = find.widgetWithText(ListTile, _backupTitle);
      return row.evaluate().isNotEmpty && tester.widget<ListTile>(row).onTap != null;
    }, 'live import session and local backup');
  }

  Future<void> openRestore(WidgetTester tester) async {
    await tester.tap(find.text(_backupTitle));
    await _until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty, 'restore confirmation');
  }

  for (final operation in ['commit', 'status']) {
    testWidgets('$operation success keeps the detached session ID when the catalog write fails', (tester) async {
      if (operation == 'status') await tester.runAsync(() => store.saveRestore(pending));
      Uint8List? catalogBeforeFailure;
      rpc.beforeResult = () async {
        catalogBeforeFailure = await File('${root.path}/catalog.enc').readAsBytes();
        // A directory at the temporary-file path fails writes even as root.
        await Directory('${root.path}/catalog.enc.tmp').create();
      };
      await pump(tester);
      if (operation == 'commit') {
        await openRestore(tester);
        await tester.tap(find.widgetWithText(TextButton, appL10n.commonConfirm));
      } else {
        await tester.tap(find.widgetWithText(TextButton, appL10n.backupCheck));
      }
      await _until(
        tester,
        () => _messageContaining(appL10n.backupRecordFailed).evaluate().isNotEmpty,
        'known result and local write failure',
      );

      expect(_messageContaining(_restoredId), findsOneWidget);
      expect(_messageContaining(appL10n.backupRestoredDetached(_restoredId)), findsOneWidget);
      expect(_messageContaining(appL10n.backupFailed('BACKUP_STORAGE_ERROR')), findsNothing);
      expect(find.widgetWithText(TextButton, appL10n.commonCancel), findsNothing);
      expect(
        rpc.methods,
        operation == 'commit'
            ? ['session.transfer.import.open', 'session.transfer.import.chunk', 'session.transfer.import.commit']
            : ['session.transfer.import.status'],
      );
      expect(store.restores, hasLength(1));
      expect(store.restores.single.pending, isTrue);
      expect(store.restores.single.target.identity, _peer.identity);
      final disk = (await tester.runAsync(() => SessionBackupStore.open(root, secrets)))!;
      expect(disk.restores.single.toJson(), store.restores.single.toJson());
      expect(disk.restores.single.sessionId, isNull);
      expect(
        await tester.runAsync(() => File('${root.path}/catalog.enc').readAsBytes()),
        orderedEquals(catalogBeforeFailure!),
      );
      if (operation == 'commit') {
        expect(rpc.calls.first.$2['batchId'], disk.restores.single.batchId);
        expect(rpc.calls.last.$2['requestId'], disk.restores.single.requestId);
      } else {
        expect(rpc.calls.single.$2, {'batchId': pending.batchId, 'requestId': pending.requestId});
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('another device cannot query the original pending request', (tester) async {
    await tester.runAsync(() => store.saveRestore(pending));
    await pump(tester, deviceId: 'replacement-device');
    await tester.tap(find.widgetWithText(TextButton, appL10n.backupCheck));
    await _until(
      tester,
      () => _messageContaining(appL10n.backupOriginalDevice).evaluate().isNotEmpty,
      'original device identity refusal',
    );

    expect(rpc.calls, isEmpty);
    expect(store.restores.single.toJson(), pending.toJson());
    final disk = (await tester.runAsync(() => SessionBackupStore.open(root, secrets)))!;
    expect(disk.restores.single.toJson(), pending.toJson());
  });

  testWidgets('another device on the same Host cannot bypass an unresolved restore', (tester) async {
    await tester.runAsync(() => store.saveRestore(pending));
    await pump(tester, deviceId: 'replacement-device');
    await tester.tap(find.text(_backupTitle));
    await _until(
      tester,
      () => _messageContaining(appL10n.backupUnknown).evaluate().isNotEmpty,
      'pending restore still blocks the same Host',
    );

    expect(find.byType(AlertDialog), findsNothing);
    expect(rpc.calls, isEmpty);
    expect(store.restores.single.toJson(), pending.toJson());
    final disk = (await tester.runAsync(() => SessionBackupStore.open(root, secrets)))!;
    expect(disk.restores.single.toJson(), pending.toJson());
  });

  testWidgets('a retired live carrier cancels before import even if its stream still has the old session', (
    tester,
  ) async {
    await pump(tester);
    await openRestore(tester);
    // Deliberately emit no stream event: _stopped must sample the carrier.
    carrier.session = null;
    await tester.tap(find.widgetWithText(TextButton, appL10n.commonConfirm));
    await _until(
      tester,
      () => _messageContaining(appL10n.backupCancelled).evaluate().isNotEmpty,
      'retired carrier cancels the old session',
    );

    expect(rpc.calls, isEmpty);
    expect(store.restores, isEmpty);
    final disk = (await tester.runAsync(() => SessionBackupStore.open(root, secrets)))!;
    expect(disk.restores, isEmpty);
    expect(disk.backups.single.toJson(), backup.toJson());
  });
}
