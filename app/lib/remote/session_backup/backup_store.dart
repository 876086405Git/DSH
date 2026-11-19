import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:dsh_remote/dsh_remote.dart' show SessionImportResult, SessionTransferData;

import '../secret_store.dart';

String newBackupId() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

class BackupPeer {
  const BackupPeer({
    required this.server,
    required this.hostId,
    required this.hostName,
    required this.fingerprint,
    required this.deviceId,
  });

  factory BackupPeer.fromJson(Map<String, dynamic> json) => BackupPeer(
    server: json['server'] as String,
    hostId: json['hostId'] as String,
    hostName: json['hostName'] as String,
    fingerprint: json['fingerprint'] as String,
    deviceId: json['deviceId'] as String,
  );

  final String server;
  final String hostId;
  final String hostName;
  final String fingerprint;
  final String deviceId;

  String get hostIdentity => jsonEncode([server, hostId, fingerprint]);

  // A pending commit may only be queried with its original device and Host.
  String get identity => jsonEncode([server, hostId, fingerprint, deviceId]);
  Map<String, Object?> toJson() => {
    'server': server,
    'hostId': hostId,
    'hostName': hostName,
    'fingerprint': fingerprint,
    'deviceId': deviceId,
  };
}

class SessionBackup {
  const SessionBackup({
    required this.id,
    required this.source,
    required this.workspaceId,
    required this.sessionId,
    required this.title,
    required this.throughSeq,
    required this.createdAt,
    required this.totalBytes,
    required this.sha256,
  });

  factory SessionBackup.fromJson(Map<String, dynamic> json) => SessionBackup(
    id: json['id'] as String,
    source: BackupPeer.fromJson(json['source'] as Map<String, dynamic>),
    workspaceId: json['workspaceId'] as String,
    sessionId: json['sessionId'] as String,
    title: json['title'] as String,
    throughSeq: json['throughSeq'] as int,
    createdAt: DateTime.parse(json['createdAt'] as String),
    totalBytes: json['totalBytes'] as int,
    sha256: json['sha256'] as String,
  );

  final String id;
  final BackupPeer source;
  final String workspaceId;
  final String sessionId;
  final String title;
  final int throughSeq;
  final DateTime createdAt;
  final int totalBytes;
  final String sha256;

  Map<String, Object?> toJson() => {
    'id': id,
    'source': source.toJson(),
    'workspaceId': workspaceId,
    'sessionId': sessionId,
    'title': title,
    'throughSeq': throughSeq,
    'createdAt': createdAt.toIso8601String(),
    'formatVersion': 1,
    'totalBytes': totalBytes,
    'sha256': sha256,
  };
}

class BackupRestore {
  const BackupRestore({
    required this.backupId,
    required this.target,
    required this.workspaceId,
    required this.batchId,
    required this.requestId,
    this.sessionId,
    this.workspaceAttached,
  });

  factory BackupRestore.fromJson(Map<String, dynamic> json) => BackupRestore(
    backupId: json['backupId'] as String,
    target: BackupPeer.fromJson(json['target'] as Map<String, dynamic>),
    workspaceId: json['workspaceId'] as String,
    batchId: json['batchId'] as String,
    requestId: json['requestId'] as String,
    sessionId: json['sessionId'] as String?,
    workspaceAttached: json['workspaceAttached'] as bool?,
  );

  final String backupId;
  final BackupPeer target;
  final String workspaceId;
  final String batchId;
  final String requestId;
  final String? sessionId;
  final bool? workspaceAttached;
  bool get pending => sessionId == null;

  BackupRestore completed(SessionImportResult result) => BackupRestore(
    backupId: backupId,
    target: target,
    workspaceId: workspaceId,
    batchId: batchId,
    requestId: requestId,
    sessionId: result.sessionId,
    workspaceAttached: result.workspaceAttached,
  );

  Map<String, Object?> toJson() => {
    'backupId': backupId,
    'target': target.toJson(),
    'workspaceId': workspaceId,
    'batchId': batchId,
    'requestId': requestId,
    'sessionId': sessionId,
    'workspaceAttached': workspaceAttached,
  };
}

/// Encrypted catalog and gzip blobs in application-private storage. The random
/// AES key lives in the platform secret store, never beside the files.
class SessionBackupStore {
  SessionBackupStore._(this.directory, this._key);

  final Directory directory;
  final SecretKey _key;
  final _aes = DartAesGcm.with256bits();
  List<SessionBackup> _backups = [];
  List<BackupRestore> _restores = [];

  List<SessionBackup> get backups => List.unmodifiable(_backups);
  List<BackupRestore> get restores => List.unmodifiable(_restores);

  static Future<SessionBackupStore> open(Directory directory, SecretStore secrets) async {
    await directory.create(recursive: true);
    const keyName = 'session_backup.v1.key';
    var encoded = await secrets.read(keyName);
    if (encoded == null) {
      // Do not replace a lost key and make existing backups look empty.
      if (await File('${directory.path}/catalog.enc').exists()) throw StateError('BACKUP_KEY_MISSING');
      final key = await DartAesGcm.with256bits().newSecretKey();
      encoded = base64Encode(await key.extractBytes());
      await secrets.write(keyName, encoded);
    }
    final store = SessionBackupStore._(directory, SecretKey(base64Decode(encoded)));
    final catalog = File('${directory.path}/catalog.enc');
    if (await catalog.exists()) {
      final json = jsonDecode(utf8.decode(await store._decrypt(await catalog.readAsBytes()))) as Map<String, dynamic>;
      if (json['version'] != 1) throw const FormatException('BACKUP_FORMAT_UNSUPPORTED');
      store._backups = (json['backups'] as List).map((e) => SessionBackup.fromJson(e as Map<String, dynamic>)).toList();
      store._restores = (json['restores'] as List)
          .map((e) => BackupRestore.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return store;
  }

  Future<Uint8List> _decrypt(List<int> bytes) async => Uint8List.fromList(
    await _aes.decrypt(SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16), secretKey: _key),
  );

  Future<void> _writeEncrypted(String name, List<int> bytes) async {
    final box = await _aes.encrypt(bytes, secretKey: _key);
    final temporary = File('${directory.path}/$name.tmp');
    await temporary.writeAsBytes(box.concatenation(), flush: true);
    await temporary.rename('${directory.path}/$name');
  }

  Future<void> _save(List<SessionBackup> backups, List<BackupRestore> restores) async {
    await _writeEncrypted(
      'catalog.enc',
      utf8.encode(
        jsonEncode({
          'version': 1,
          'backups': backups.map((e) => e.toJson()).toList(),
          'restores': restores.map((e) => e.toJson()).toList(),
        }),
      ),
    );
    _backups = backups;
    _restores = restores;
  }

  Future<void> add(SessionBackup backup, SessionTransferData data) async {
    await _writeEncrypted('${backup.id}.enc', data.gzipBytes);
    await _save([backup, ..._backups], _restores);
  }

  Future<SessionTransferData> read(SessionBackup backup) async => SessionTransferData(
    gzipBytes: await _decrypt(await File('${directory.path}/${backup.id}.enc').readAsBytes()),
    totalBytes: backup.totalBytes,
    sha256: backup.sha256,
  );

  Future<void> saveRestore(BackupRestore restore) =>
      _save(_backups, [restore, ..._restores.where((e) => e.requestId != restore.requestId)]);

  Future<void> forgetRestore(BackupRestore restore) =>
      _save(_backups, _restores.where((e) => e.requestId != restore.requestId).toList());

  Future<void> delete(SessionBackup backup) async {
    // Remove the published entry first; an interrupted delete leaves only an
    // encrypted orphan, never a catalog entry whose file is already missing.
    await _save(
      _backups.where((e) => e.id != backup.id).toList(),
      _restores.where((e) => e.backupId != backup.id).toList(),
    );
    final file = File('${directory.path}/${backup.id}.enc');
    if (await file.exists()) await file.delete();
  }
}
