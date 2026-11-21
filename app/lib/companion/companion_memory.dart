// One database per phone folder, shared by both room modes and the memories
// page. Vitals remain with their existing phone/host owner.

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

import 'companion_local.dart';
import 'companion_host_tasks.dart';
import 'companion_memory_worker.dart';
import 'companion_public_lookup.dart';
import 'companion_widget.dart';

/// Key by the absolute folder path, not Directory object identity. This
/// provider stays alive across room visits; it owns the Dart connection. The
/// reminder executor uses the same database from its private native process.
final companionMemoryOwnerProvider = FutureProvider.family<CompanionMemoryOwner, String>((ref, rootPath) async {
  final root = Directory(rootPath);
  await root.create(recursive: true);
  if (!ref.mounted) throw const DshClosedException('Memory owner closed');
  final memory = CompanionMemoryOwner(
    CompanionMemoryStore(
      sqlite3.open('${root.path}/memory.sqlite'),
      nowMilliseconds: () => DateTime.now().millisecondsSinceEpoch,
    ),
    CompanionLocal.at(root),
  );
  ref.onDispose(memory.dispose);
  return memory;
});

class CompanionMemoryOwner extends ChangeNotifier {
  CompanionMemoryOwner(this.store, this.legacy, {int Function()? nowMilliseconds})
    : _now = nowMilliseconds ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CompanionMemoryStore store;
  final CompanionLocal legacy;
  final int Function() _now;
  late final lookups = CompanionLookups(
    store: store,
    nowMilliseconds: _now,
    changed: changed,
    retainReceipt: retainReceipt,
  );
  late final hostTasks = CompanionHostTasks(store: store, changed: changed, retainReceipt: retainReceipt);
  Future<bool>? _localMigration;
  Future<bool>? _widgetClear;
  final Map<DshClient, Future<bool>> _hostMigrations = {};
  final Set<Future<void>> _receipts = {};
  final Map<String, Future<void>> _usageReads = {};
  final Map<String, ({int at, int delay})> _usageAttempts = {};
  CompanionMemoryWorker? _worker;
  CompanionMemoryTransport? Function()? _route;
  Object? _room;
  bool _disposed = false;

  void enter(
    Object room, {
    required CompanionMemoryTransport? Function() transport,
    required int Function(String) estimateTokens,
  }) {
    if (!identical(_room, room)) _worker?.cancel();
    _room = room;
    _route = transport;
    _worker ??= CompanionMemoryWorker(
      store: store,
      transport: () => _route!(),
      nowMilliseconds: _now,
      estimateTokens: estimateTokens,
    );
  }

  Future<CompanionMemoryWork> extract(Object room, {bool forceTail = false}) async {
    if (!identical(_room, room)) return CompanionMemoryWork.idle;
    final result = await _worker!.extract(forceTail: forceTail);
    if (result == CompanionMemoryWork.committed) changed();
    return result;
  }

  Future<String?> followup(
    Object room,
    MemoryRow captured, {
    required String persona,
    required int offsetMinutes,
    required bool Function() isCurrent,
  }) => identical(_room, room)
      ? _worker!.followup(captured, persona: persona, offsetMinutes: offsetMinutes, isCurrent: isCurrent)
      : Future.value(null);

  Future<CompanionMemoryWork> consolidate(Object room) async {
    if (!identical(_room, room)) return CompanionMemoryWork.idle;
    final before = store.archive['memory_revision'];
    try {
      return await _worker!.consolidate();
    } finally {
      // Local exact merges can commit even when a later cloud step cannot run.
      if (!_disposed && store.archive['memory_revision'] != before) changed();
    }
  }

  void leave(Object room) {
    if (!identical(_room, room)) return;
    _worker?.cancel();
    _room = null;
  }

  void cancelWork() => _worker?.cancel();

  /// Chat usage and explicit task commands can finish after leaving the
  /// room. Register their drain before dispatch so disposal cannot close
  /// SQLite before the final receipt is read or recorded.
  void retainReceipt(Future<void> settled) {
    _receipts.add(settled);
    unawaited(
      settled.then<void>(
        (_) {
          _receipts.remove(settled);
        },
        onError: (Object _) {
          _receipts.remove(settled);
        },
      ),
    );
  }

  /// Pull metadata for saved deliveries, including an old Session or bridge
  /// instance. Never rediscover its identity or resend its model prompt.
  Future<void> refreshHostChatUsage(DshClient client, String hostKey) {
    if (_disposed) return Future.value();
    return _usageReads.putIfAbsent(hostKey, () {
      final read = _readHostChatUsage(client, hostKey);
      retainReceipt(read);
      return read.whenComplete(() {
        _usageReads.remove(hostKey);
      });
    });
  }

  Future<void> _readHostChatUsage(DshClient client, String hostKey) async {
    final now = _now();
    final pending =
        store.pendingHostChatDeliveries(hostKey).where((row) {
          final attempt = _usageAttempts[row['id']];
          return attempt == null || now < attempt.at || now - attempt.at >= attempt.delay;
        }).toList()..sort((a, b) {
          final first = _usageAttempts[a['id']]?.at ?? -1;
          final second = _usageAttempts[b['id']]?.at ?? -1;
          return first != second
              ? first.compareTo(second)
              : (a['observed_at_ms'] as int).compareTo(b['observed_at_ms'] as int);
        });
    // Bound one read opportunity and let the next room tick visit older roots.
    // Completed immutable receipts leave the queue even when fees are unknown.
    for (final delivery in pending.take(4)) {
      if (_disposed) break;
      final id = delivery['id']! as String;
      final attempted = _now();
      _usageAttempts[id] = (at: attempted, delay: 5 * 60000);
      try {
        final snapshot = await client.readCompanionChatUsage(
          instanceId: delivery['instance_id']! as String,
          sessionId: delivery['session_id']! as String,
          requestId: delivery['request_id']! as String,
        );
        if (snapshot == null) continue;
        if (store.importHostChatUsage(deliveryId: id, snapshot: snapshot.toJson())) changed();
        _usageAttempts[id] = (at: attempted, delay: snapshot.state == 'unknown' ? 5 * 60000 : 15000);
      } on Object {
        // A failed read proves neither a free request nor a new bridge identity.
        // Known receipts remain; a later read opportunity may obtain more.
      }
    }
  }

  /// A missing old file stays missing. Corrupt or changed sources throw and
  /// remain intact; callers can show that migration needs attention.
  Future<bool> migrateLocal() => _localMigration ??= _migrateLocal().whenComplete(() => _localMigration = null);

  Future<bool> _migrateLocal() async {
    final source = await legacy.probeForMigration();
    if (source == null) return true;
    final ids = store.importLegacy(source, realityKnownIds: {for (final memory in source.memories) memory.id});
    store.finishMissingLegacyCleanup(source);
    changed();
    if (ids.isEmpty) return !_cleanupPending(source.storeId);
    if (!store.verifyLegacyImport(source, ids)) throw StateError('Memory migration readback failed');
    await legacy.removeMigratedMemories(source.storeId, source.revision, ids.toSet());
    store.finishLegacyCleanup(source.storeId, ids, expectedReadRevision: source.revision);
    return !_cleanupPending(source.storeId);
  }

  /// Every card is first imported and read back from the original snapshot.
  /// Each subsequent delete uses only the revision in our own strict receipt.
  Future<bool> migrateHost(DshClient client) => _hostMigrations.putIfAbsent(
    client,
    () => _migrateHost(client).whenComplete(() {
      _hostMigrations.remove(client);
    }),
  );

  Future<bool> _migrateHost(DshClient client) async {
    final source = await client.companionMemoriesForMigration();
    final ids = store.importLegacy(source, realityKnownIds: {for (final memory in source.memories) memory.id});
    store.finishMissingLegacyCleanup(source);
    changed();
    if (ids.isEmpty) return !_cleanupPending(source.storeId);
    if (!store.verifyLegacyImport(source, ids)) throw StateError('Memory migration readback failed');
    var read = source;
    for (final id in ids) {
      read = await client.deleteMigratedCompanionMemory(read, id);
      store.finishLegacyCleanup(source.storeId, [id], expectedReadRevision: source.revision);
    }
    return !_cleanupPending(source.storeId);
  }

  bool _cleanupPending(String id) => store.migrationCleanup().any((row) => row['legacy_store_id'] == id);

  MemorySelection select(String input) {
    final cards = store.cards();
    return selectMemoryContext(
      cards,
      input: input,
      nowMs: _now(),
      controlRevision: store.archive['control_revision']! as int,
      explicitTopicIds: explicitMemoryTopics(input, cards),
    );
  }

  /// A control transaction leaves this pending until native storage confirms
  /// both fields cleared. Room and memory page share the same draining write.
  Future<bool> clearWidget(CompanionWidget widget) =>
      _widgetClear ??= _clearWidget(widget).whenComplete(() => _widgetClear = null);

  Future<bool> _clearWidget(CompanionWidget widget) async {
    while (true) {
      final archive = store.archive;
      if (archive['widget_clear_pending'] != 1) return true;
      final revision = archive['control_revision']! as int;
      if (!await widget.clearMemoryLine(archiveId: archive['id']! as String, controlRevision: revision)) return false;
      store.acknowledgeWidgetClear(controlRevision: revision);
      changed();
    }
  }

  Map<String, Object?> phoneContext(MemorySelection selection) {
    final archive = store.archive;
    if (selection.controlRevision != archive['control_revision']) {
      throw const DshRemoteException('companion/conflict', 'Memory control changed', {'status': 409});
    }
    return {
      'archiveId': archive['id'],
      'controlRevision': selection.controlRevision,
      'historyAfterSeq': archive['history_after_seq'],
      'block': selection.block,
    };
  }

  void changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _room = null;
    final pending = <Future<void>>[
      ..._receipts,
      if (_localMigration != null) _localMigration!.then<void>((_) {}),
      if (_widgetClear != null) _widgetClear!.then<void>((_) {}),
      for (final task in _hostMigrations.values) task.then<void>((_) {}),
      if (_worker != null) _worker!.stop(),
    ];
    if (pending.isEmpty) {
      store.close();
    } else {
      // Receipts from a cancelled request finish before its connection closes.
      unawaited(Future.wait([for (final task in pending) task.catchError((Object _) {})]).then((_) => store.close()));
    }
    super.dispose();
  }
}
