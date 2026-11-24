// One database per phone folder, shared by both room modes and the memories
// page. Relationship facts and maintenance belong to this same phone owner.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

import 'companion_agent_tools.dart';
import 'companion_local.dart';
import 'companion_host_tasks.dart';
import 'companion_memory_embeddings.dart';
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
  CompanionMemoryOwner(
    this.store,
    this.legacy, {
    int Function()? nowMilliseconds,
    CompanionMemoryEmbeddings? embeddings,
  }) : _now = nowMilliseconds ?? (() => DateTime.now().millisecondsSinceEpoch),
       embeddings = embeddings ?? CompanionMemoryEmbeddings();

  final CompanionMemoryStore store;
  final CompanionLocal legacy;
  final CompanionMemoryEmbeddings embeddings;
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
  FutureOr<CompanionMemoryTransport?> Function()? _route;
  Object? _room;
  bool _roomReady = false;
  bool _disposed = false;
  Timer? _rawEraseExpiryTimer;
  String? _rawEraseTimerId;
  int? _rawEraseTimerDeadline;
  int? _rawEraseTimerControlRevision;

  bool get working => _worker?.busy == true;

  /// The Store owns the one plan. A projection never offers it or notifies
  /// listeners from inside a widget build.
  CompanionPendingRawErase? pendingRawErase(Object room, {required String? characterId}) =>
      _disposed || !identical(_room, room) ? null : store.pendingRawErase(characterId: characterId);

  CompanionRawEraseResult markRawEraseOffered(Object room, String id, {required String? characterId}) {
    _checkRawEraseRoom(room);
    final result = store.markRawEraseOffered(id, characterId: characterId);
    if (result.state == 'awaiting') {
      final pending = store.pendingRawErase(characterId: characterId);
      if (pending != null && pending.id == id) _watchRawEraseExpiry(pending);
    }
    return _rawEraseChanged(result);
  }

  CompanionRawEraseResult confirmRawErase(Object room, String id, {required String? characterId}) {
    _checkRawEraseRoom(room);
    return _rawEraseChanged(store.confirmRawErase(id, characterId: characterId));
  }

  CompanionRawEraseResult declineRawErase(Object room, String id, {required String? characterId}) {
    _checkRawEraseRoom(room);
    return _rawEraseChanged(store.declineRawErase(id, characterId: characterId));
  }

  void _checkRawEraseRoom(Object room) {
    if (_disposed || !identical(_room, room)) throw const DshClosedException('Companion memory room closed');
  }

  CompanionRawEraseResult _rawEraseChanged(CompanionRawEraseResult result) {
    if (result.id == _rawEraseTimerId && result.state != 'awaiting' && result.state != 'deferred') {
      _cancelRawEraseExpiry();
    }
    // Confirmation is the person's external control commit, never an
    // acknowledgement on behalf of a closed model/tool turn.
    changed();
    return result;
  }

  void _watchRawEraseExpiry(CompanionPendingRawErase pending) {
    final deadline = pending.expiresAtUtcMs;
    if (deadline == null || (pending.id == _rawEraseTimerId && deadline == _rawEraseTimerDeadline)) return;
    _cancelRawEraseExpiry();
    final id = _rawEraseTimerId = pending.id;
    _rawEraseTimerDeadline = deadline;
    _rawEraseTimerControlRevision = store.archive['control_revision']! as int;
    final delay = deadline - _now();
    _rawEraseExpiryTimer = Timer(Duration(milliseconds: delay > 0 ? delay : 0), () {
      if (_disposed || _rawEraseTimerId != id || _rawEraseTimerDeadline != deadline) return;
      _cancelRawEraseExpiry();
      // The real getter/action still validates the clock and every Store
      // fence. This timer only asks the current UI to refresh its projection.
      changed();
    });
  }

  void _cancelRawEraseExpiry() {
    _rawEraseExpiryTimer?.cancel();
    _rawEraseExpiryTimer = null;
    _rawEraseTimerId = null;
    _rawEraseTimerDeadline = null;
    _rawEraseTimerControlRevision = null;
  }

  bool invalidateRawErase(Object room, {bool notify = true}) {
    // An old Visit may close after another Visit entered this phone Owner.
    // Do not even cancel the later plan's timer before checking its identity.
    if (_disposed || !identical(_room, room)) return false;
    final invalidated = store.invalidateRawErase();
    _cancelRawEraseExpiry();
    if (invalidated && notify) changed();
    return invalidated;
  }

  void enter(
    Object room, {
    required FutureOr<CompanionMemoryTransport?> Function() transport,
    required int Function(String) estimateTokens,
    String? characterId,
    bool ready = true,
  }) {
    if (!identical(_room, room)) _worker?.cancel();
    _room = room;
    _roomReady = ready;
    _route = transport;
    // A deferred record may outlive an external window's Visit. Reuse only
    // its original id and the current real role; entering does not offer it.
    if (store.pendingRawErase(characterId: characterId) == null) _cancelRawEraseExpiry();
    _worker ??= CompanionMemoryWorker(
      store: store,
      transport: () => _route!(),
      nowMilliseconds: _now,
      estimateTokens: estimateTokens,
      maintenanceTools: (turn, current, onCommitted) => CompanionAgentMemoryTools.maintenance(
        memory: this,
        turn: turn,
        isCurrent: current,
        onMaintenanceCommitted: onCommitted,
        forgottenNotice: '',
        semanticRecall: (query) => recallIds(query, characterId: turn['character_id'] as String?, isCurrent: current),
      ),
    );
  }

  /// A Visit owns its close/invalidation identity before initialization awaits,
  /// but maintenance keeps its original start point after those awaits finish.
  void finishOpening(Object room) {
    if (_disposed || !identical(_room, room)) return;
    _roomReady = true;
    changed();
  }

  bool acceptsMaintenanceControl(Object room, int revision) =>
      identical(_room, room) && _roomReady && _worker?.acceptsControl(revision) == true;

  Future<CompanionMemoryWork> extract(Object room, {bool forceTail = false, int? offsetMinutes}) async {
    if (!identical(_room, room) || !_roomReady) return CompanionMemoryWork.idle;
    final result = await _worker!.extract(forceTail: forceTail, offsetMinutes: offsetMinutes);
    if (result == CompanionMemoryWork.committed) changed();
    return result;
  }

  Future<String?> followup(
    Object room,
    MemoryRow captured, {
    required String persona,
    required int offsetMinutes,
    required bool Function() isCurrent,
  }) => identical(_room, room) && _roomReady
      ? _worker!.followup(captured, persona: persona, offsetMinutes: offsetMinutes, isCurrent: isCurrent)
      : Future.value(null);

  Future<CompanionMemoryWork> consolidate(Object room, {int? offsetMinutes}) async {
    if (!identical(_room, room) || !_roomReady) return CompanionMemoryWork.idle;
    final before = store.archive['memory_revision'];
    try {
      return await _worker!.consolidate(offsetMinutes: offsetMinutes);
    } finally {
      // A confirmed tool write survives a later network or budget stop.
      if (!_disposed && store.archive['memory_revision'] != before) changed();
    }
  }

  void leave(Object room, {String? characterId, bool actualRoomLeave = false}) {
    if (_disposed || !identical(_room, room)) return;
    // A notification/float that never offered confirmation may retire while
    // this phone Owner survives. The next real room reads the same deferred
    // id. Actual room departure and an already offered record both revoke it.
    final pending = actualRoomLeave ? null : store.pendingRawErase(characterId: characterId);
    final invalidated = (actualRoomLeave || pending == null || pending.expiresAtUtcMs != null) &&
        store.invalidateRawErase();
    _cancelRawEraseExpiry();
    _roomReady = false;
    _worker?.cancel();
    _room = null;
    // A Visit leaves from inside its Page's dispose, while other pages over it
    // may be coming down in the same frame. Only a plan actually revoked here
    // is news to the listeners that remain; an ordinary leave stays quiet.
    if (invalidated) changed();
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
    // Read opportunities only come on opening and connection changes now, so
    // one visits every root. Completed immutable receipts leave the queue even
    // when fees are unknown.
    for (final delivery in pending) {
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

  Future<List<String>?> recallIds(
    String query, {
    String? explicitUserInput,
    required String? characterId,
    required bool Function() isCurrent,
  }) async {
    final revision = store.archive['control_revision'];
    bool current() => !_disposed && isCurrent() && store.archive['control_revision'] == revision;
    final ranked = await embeddings.rank(
      store: store,
      characterId: characterId,
      query: query,
      explicitInput: explicitUserInput,
      isCurrent: current,
    );
    if (!current()) throw const CompanionMemoryRetrievalCancelled();
    return ranked == null ? null : [for (final row in ranked) row['id']! as String];
  }

  /// Fixed impression and the last two completed diary dates are separate
  /// from card ranking. A vector result cannot crowd those layers out.
  /// Observation text can guide relevance; only an actual user source supplies
  /// [explicitUserInput] for the one-selection quiet exception.
  Future<MemorySelection> selectForAgent(
    String input, {
    required String? characterId,
    required int offsetMinutes,
    required bool Function() isCurrent,
    String? explicitUserInput,
  }) async {
    final revision = store.archive['control_revision']! as int;
    bool current() => !_disposed && isCurrent() && store.archive['control_revision'] == revision;
    // Without the model rank would read every candidate only to tell [] from
    // null; the read below is the one the selection uses, so skip the first.
    final ranked = embeddings.knownUnavailable
        ? null
        : await embeddings.rank(
            store: store,
            characterId: characterId,
            query: input,
            explicitInput: explicitUserInput,
            isCurrent: current,
          );
    if (!current()) throw const CompanionMemoryRetrievalCancelled();
    final cards = store.memoryRetrievalCandidates(characterId: characterId, input: explicitUserInput);
    // Scope resolved the invitation in the whole domain. Its matching row
    // can belong to a fixed layer, outside these returned ordinary candidates.
    final explicit = <String>{
      for (final card in cards)
        if (card['topic_mode'] == 'never') card['topic_id']! as String,
    };
    final selection = ranked == null
        ? selectMemoryContext(cards, input: input, nowMs: _now(), controlRevision: revision, explicitTopicIds: explicit)
        : selectRankedMemoryContext(
            cards,
            rankedIds: [for (final row in ranked) row['id']! as String],
            nowMs: _now(),
            controlRevision: revision,
            explicitTopicIds: explicit,
          );
    final local = DateTime.fromMillisecondsSinceEpoch(_now() + offsetMinutes * 60000, isUtc: true);
    final today = DateTime.utc(local.year, local.month, local.day);
    final firstDay = today.subtract(const Duration(days: 2)).toIso8601String().substring(0, 10);
    final todayKey = today.toIso8601String().substring(0, 10);
    final fixed = store.memoryFixedLayerCards(
      characterId: characterId,
      fromDay: firstDay,
      beforeDay: todayKey,
      explicitUserInput: explicitUserInput,
    );
    final diaries = fixed.where((row) => row['layer'] == 'diary').toList()
      ..sort((a, b) => (a['local_day']! as String).compareTo(b['local_day']! as String));
    final selected = [
      ...fixed.where((row) => row['layer'] == 'impression'),
      for (final id in selection.ids) cards.singleWhere((row) => row['id'] == id),
      ...diaries,
    ];
    return MemorySelection(
      block: jsonEncode({
        'type': 'companion_memory',
        'version': 3,
        'scope': 'real',
        'items': [
          for (final row in selected)
            {
              'id': row['id'],
              'kind': row['kind'],
              'layer': row['layer'],
              'collection': row['collection'],
              'text': row['text'],
              if (row['source'] != null) 'source': row['source'],
              if (row['local_day'] != null) 'local_day': row['local_day'],
            },
        ],
      }),
      ids: [for (final row in selected) row['id']! as String],
      controlRevision: revision,
    );
  }

  /// The SDK supplies the stage and recovery fact. Tone follows real shared
  /// history and the person's preferred form of address; initiative consent stays.
  String relationshipContext(String? characterId, {bool forInitiative = false}) {
    if (characterId == null) return '';
    final affinity = store.companionAffinity(characterId: characterId);
    final tier = affinity?['tier'] as int? ?? 0;
    return '\n${jsonEncode({
      'type': 'companion_relationship',
      'stage': const ['just_met', 'familiar', 'friends', 'close', 'very_close', 'inseparable'][tier],
      'recovering': affinity != null && (affinity['score_milli']! as int) < (affinity['peak_milli']! as int),
      'guidance': 'Let familiarity shape warmth, playfulness and how much of your own day you share. '
          'Respect the person\'s preferred form of address. You may naturally choose a nickname based on real interactions, '
          'but do not present a new nickname as previously agreed or invent shared events. '
          'When returning after absence, acknowledge it gently; no fixed stage unlocks a scripted sentence.',
      if (forInitiative) 'initiative': 'This is an optional opportunity, not a demand to speak. '
            'When newly acquainted, prefer silent if asking now would presume familiarity. '
            'As genuine familiarity grows, be more willing to make a natural small approach. '
            'Still choose silent when the question would intrude or repeat what was already said. '
            'The person\'s chosen pace, quiet hours and invitation limits always remain in force.',
    })}';
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

  void clearNoticeMemories() {
    store.clearNoticeMemories();
    changed();
  }

  void changed() {
    if (_disposed) return;
    if (_rawEraseTimerControlRevision != null &&
        store.archive['control_revision'] != _rawEraseTimerControlRevision) {
      _cancelRawEraseExpiry();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.invalidateRawErase();
    _cancelRawEraseExpiry();
    _room = null;
    _roomReady = false;
    embeddings.dispose();
    hostTasks.closeForegrounds();
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
