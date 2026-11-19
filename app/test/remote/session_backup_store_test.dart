import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/session_backup/backup_store.dart';
import 'package:dsh_remote/dsh_remote.dart' show SessionImportResult, SessionTransferData;
import 'package:flutter_test/flutter_test.dart';

const _keyName = 'session_backup.v1.key';
const _firstId = '00000000000000000000000000000001';
const _secondId = '00000000000000000000000000000002';
const _message = 'Private conversation content that must never be stored as plaintext.';
const _source = BackupPeer(
  server: 'https://source.example.invalid',
  hostId: 'private-source-host-id',
  hostName: 'Private source host name',
  fingerprint: 'private-source-fingerprint',
  deviceId: 'private-source-device-id',
);
const _target = BackupPeer(
  server: 'https://target.example.invalid',
  hostId: 'private-target-host-id',
  hostName: 'Private target host name',
  fingerprint: 'private-target-fingerprint',
  deviceId: 'private-target-device-id',
);

SessionTransferData _data() {
  final bytes = Uint8List.fromList(gzip.encode(utf8.encode(_message)));
  return SessionTransferData(
    gzipBytes: bytes,
    totalBytes: bytes.length,
    sha256: crypto.sha256.convert(bytes).toString(),
  );
}

SessionBackup _backup(SessionTransferData data, {String id = _firstId}) => SessionBackup(
  id: id,
  source: _source,
  workspaceId: 'private-source-workspace-id',
  sessionId: 'private-source-session-$id',
  title: 'Private conversation title',
  throughSeq: 1729,
  createdAt: DateTime.utc(2026, 11, 19, 12, 30),
  totalBytes: data.totalBytes,
  sha256: data.sha256,
);

BackupRestore _pending(SessionBackup backup, {String requestId = 'private-request-one'}) => BackupRestore(
  backupId: backup.id,
  target: _target,
  workspaceId: 'private-target-workspace-id',
  batchId: 'private-batch-id',
  requestId: requestId,
);

void main() {
  late Directory root;
  late Directory directory;
  late MemorySecretStore secrets;
  late SessionBackupStore store;
  late SessionTransferData data;
  late SessionBackup backup;

  Future<SessionBackupStore> reopen() => SessionBackupStore.open(directory, secrets);
  File blob(SessionBackup entry) => File('${directory.path}/${entry.id}.enc');
  File catalog() => File('${directory.path}/catalog.enc');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('session-backup-store-');
    addTearDown(() => root.delete(recursive: true));
    directory = Directory('${root.path}/app-private/session-backups');
    secrets = MemorySecretStore();
    data = _data();
    backup = _backup(data);
    store = await SessionBackupStore.open(directory, secrets);
  });

  test('creates an isolated directory and reuses its secret-store key', () async {
    expect(await directory.exists(), isTrue);
    expect(store.backups, isEmpty);
    expect(store.restores, isEmpty);
    expect(secrets.values.keys, [_keyName]);
    final encodedKey = secrets.values[_keyName]!;
    expect(base64Decode(encodedKey), hasLength(32));
    expect(await directory.list().toList(), isEmpty);

    final reopened = await reopen();
    expect(reopened.backups, isEmpty);
    expect(reopened.restores, isEmpty);
    expect(secrets.values, {_keyName: encodedKey});
  });

  test('encrypts gzip content, catalog metadata and pending identifiers on disk', () async {
    await store.add(backup, data);
    final pending = _pending(backup);
    await store.saveRestore(pending);

    final payload = await blob(backup).readAsBytes();
    final encryptedCatalog = await catalog().readAsBytes();
    expect(payload, hasLength(data.gzipBytes.length + 12 + 16));
    expect(payload, isNot(orderedEquals(data.gzipBytes)));
    expect(latin1.decode(payload), isNot(contains(latin1.decode(data.gzipBytes))));
    expect(encryptedCatalog, isNot(orderedEquals(utf8.encode(jsonEncode(backup.toJson())))));

    final key = secrets.values[_keyName]!;
    for (final bytes in [payload, encryptedCatalog]) {
      final text = utf8.decode(bytes, allowMalformed: true);
      for (final marker in [
        _message,
        backup.title,
        backup.workspaceId,
        backup.sessionId,
        backup.sha256,
        ..._source.toJson().values.cast<String>(),
        ..._target.toJson().values.cast<String>(),
        pending.workspaceId,
        pending.batchId,
        pending.requestId,
        key,
      ]) {
        expect(text, isNot(contains(marker)));
      }
      expect(latin1.decode(bytes), isNot(contains(latin1.decode(base64Decode(key)))));
    }
    expect(
      await directory.list().map((entry) => entry.uri.pathSegments.last).toList(),
      unorderedEquals(['catalog.enc', '${backup.id}.enc']),
    );
  });

  test('uses different nonces for identical gzip snapshots', () async {
    final other = _backup(data, id: _secondId);
    await store.add(backup, data);
    await store.add(other, data);

    final first = await blob(backup).readAsBytes();
    final second = await blob(other).readAsBytes();
    expect(first, isNot(orderedEquals(second)));
    expect(first.take(12), isNot(orderedEquals(second.take(12))));
    expect((await store.read(other)).gzipBytes, orderedEquals(data.gzipBytes));
  });

  test('reopens metadata and the exact gzip bytes using the persisted key', () async {
    await store.add(backup, data);
    final keyBefore = Map<String, String>.of(secrets.values);

    final reopened = await reopen();
    expect(reopened.backups, hasLength(1));
    final restoredBackup = reopened.backups.single;
    expect(restoredBackup.toJson(), backup.toJson());
    expect(restoredBackup.source.identity, _source.identity);
    final read = await reopened.read(restoredBackup);
    expect(read.gzipBytes, orderedEquals(data.gzipBytes));
    expect(read.totalBytes, data.gzipBytes.length);
    expect(read.sha256, crypto.sha256.convert(read.gzipBytes).toString());
    expect(utf8.decode(gzip.decode(read.gzipBytes)), _message);
    expect(secrets.values, keyBefore);
  });

  test('persists the original pending Host, device, batch and request before completion', () async {
    await store.add(backup, data);
    final pending = _pending(backup);
    await store.saveRestore(pending);

    final reopened = await reopen();
    expect(reopened.restores, hasLength(1));
    final saved = reopened.restores.single;
    expect(saved.toJson(), pending.toJson());
    expect(saved.target.identity, _target.identity);
    final anotherDevice = BackupPeer(
      server: _target.server,
      hostId: _target.hostId,
      hostName: _target.hostName,
      fingerprint: _target.fingerprint,
      deviceId: 'private-new-device-id',
    );
    expect(saved.target.hostIdentity, anotherDevice.hostIdentity);
    expect(saved.target.identity, isNot(anotherDevice.identity));
    expect(saved.target.deviceId, _target.deviceId);
    expect(saved.pending, isTrue);
    expect(saved.sessionId, isNull);
    expect(saved.workspaceAttached, isNull);
    expect((await reopened.read(reopened.backups.single)).gzipBytes, orderedEquals(data.gzipBytes));
  });

  for (final attached in [true, false]) {
    test('persists completion with workspaceAttached=$attached without duplicating the request', () async {
      await store.add(backup, data);
      final pending = _pending(backup);
      final unrelated = _pending(backup, requestId: 'private-request-two');
      await store.saveRestore(pending);
      await store.saveRestore(unrelated);

      final beforeCommit = await reopen();
      final savedPending = beforeCommit.restores.singleWhere((entry) => entry.requestId == pending.requestId);
      final completed = savedPending.completed(
        SessionImportResult(sessionId: 'private-imported-session-id', workspaceAttached: attached),
      );
      await beforeCommit.saveRestore(completed);

      final reopened = await reopen();
      expect(reopened.restores, hasLength(2));
      final saved = reopened.restores.singleWhere((entry) => entry.requestId == pending.requestId);
      expect(saved.toJson(), completed.toJson());
      expect(saved.pending, isFalse);
      expect(saved.sessionId, 'private-imported-session-id');
      expect(saved.workspaceAttached, attached);
      expect(saved.target.identity, pending.target.identity);
      expect(
        reopened.restores.singleWhere((entry) => entry.requestId == unrelated.requestId).toJson(),
        unrelated.toJson(),
      );
    });
  }

  test('forgets only the requested restore and preserves the backup after reopening', () async {
    await store.add(backup, data);
    final first = _pending(backup);
    final second = _pending(backup, requestId: 'private-request-two');
    await store.saveRestore(first);
    await store.saveRestore(second);
    await store.forgetRestore(first);

    final reopened = await reopen();
    expect(reopened.restores.map((entry) => entry.toJson()), [second.toJson()]);
    expect(reopened.backups.single.toJson(), backup.toJson());
    expect((await reopened.read(reopened.backups.single)).gzipBytes, orderedEquals(data.gzipBytes));
  });

  test('rejects a lost key without generating a replacement or overwriting files', () async {
    await store.add(backup, data);
    final catalogBefore = await catalog().readAsBytes();
    final blobBefore = await blob(backup).readAsBytes();
    await secrets.delete(_keyName);

    await expectLater(
      reopen(),
      throwsA(isA<StateError>().having((error) => error.message, 'message', 'BACKUP_KEY_MISSING')),
    );
    expect(secrets.values, isEmpty);
    expect(await catalog().readAsBytes(), orderedEquals(catalogBefore));
    expect(await blob(backup).readAsBytes(), orderedEquals(blobBefore));
  });

  test('rejects a different valid AES key instead of presenting an empty catalog', () async {
    await store.add(backup, data);
    final encrypted = await catalog().readAsBytes();
    final wrongKey = base64Decode(secrets.values[_keyName]!);
    wrongKey[0] ^= 1;
    await secrets.write(_keyName, base64Encode(wrongKey));

    await expectLater(reopen(), throwsA(isA<SecretBoxAuthenticationError>()));
    expect(await catalog().readAsBytes(), orderedEquals(encrypted));
    expect(secrets.values[_keyName], base64Encode(wrongKey));
  });

  for (final part in ['nonce', 'ciphertext', 'tag']) {
    test('rejects a changed gzip $part without losing the catalog entry', () async {
      await store.add(backup, data);
      final bytes = await blob(backup).readAsBytes();
      final index = switch (part) {
        'nonce' => 0,
        'ciphertext' => 12,
        _ => bytes.length - 1,
      };
      bytes[index] ^= 1;
      await blob(backup).writeAsBytes(bytes, flush: true);

      final reopened = await reopen();
      expect(reopened.backups.single.toJson(), backup.toJson());
      await expectLater(reopened.read(reopened.backups.single), throwsA(isA<SecretBoxAuthenticationError>()));
      expect(await blob(backup).readAsBytes(), orderedEquals(bytes));
    });
  }

  test('rejects an authenticated-catalog failure without rewriting it', () async {
    await store.add(backup, data);
    final bytes = await catalog().readAsBytes();
    bytes[12] ^= 1;
    await catalog().writeAsBytes(bytes, flush: true);

    await expectLater(reopen(), throwsA(isA<SecretBoxAuthenticationError>()));
    expect(await catalog().readAsBytes(), orderedEquals(bytes));
    expect(await blob(backup).exists(), isTrue);
  });

  test('reports a missing gzip file rather than returning an empty snapshot', () async {
    await store.add(backup, data);
    await blob(backup).delete();

    final reopened = await reopen();
    expect(reopened.backups.single.toJson(), backup.toJson());
    await expectLater(reopened.read(reopened.backups.single), throwsA(isA<FileSystemException>()));
  });

  test('deletes the blob and all its restore records but preserves another backup', () async {
    final other = _backup(data, id: _secondId);
    await store.add(backup, data);
    await store.add(other, data);
    await store.saveRestore(_pending(backup));
    await store.saveRestore(
      _pending(
        backup,
        requestId: 'private-request-completed',
      ).completed(const SessionImportResult(sessionId: 'private-imported-session-id', workspaceAttached: false)),
    );
    final keep = _pending(other, requestId: 'private-request-keep');
    await store.saveRestore(keep);
    final keyBefore = Map<String, String>.of(secrets.values);

    await store.delete(backup);

    expect(store.backups.map((entry) => entry.id), [other.id]);
    expect(store.restores.map((entry) => entry.requestId), [keep.requestId]);
    expect(await blob(backup).exists(), isFalse);
    final reopened = await reopen();
    expect(reopened.backups.single.toJson(), other.toJson());
    expect(reopened.restores.single.toJson(), keep.toJson());
    expect((await reopened.read(reopened.backups.single)).gzipBytes, orderedEquals(data.gzipBytes));
    expect(secrets.values, keyBefore);
    expect(
      await directory.list().map((entry) => entry.uri.pathSegments.last).toList(),
      unorderedEquals(['catalog.enc', '${other.id}.enc']),
    );
  });

  test('deleting the last backup persists an empty catalog and permits a new backup', () async {
    await store.add(backup, data);
    await store.saveRestore(_pending(backup));
    await store.delete(backup);

    final reopened = await reopen();
    expect(reopened.backups, isEmpty);
    expect(reopened.restores, isEmpty);
    expect(await blob(backup).exists(), isFalse);
    expect(await catalog().exists(), isTrue);
    await reopened.add(backup, data);
    final finalStore = await reopen();
    expect(finalStore.backups.single.toJson(), backup.toJson());
    expect((await finalStore.read(finalStore.backups.single)).gzipBytes, orderedEquals(data.gzipBytes));
  });
}
