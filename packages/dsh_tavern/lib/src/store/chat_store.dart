import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../api.dart';
import '../authoring.dart';
import '../authoring_run.dart';
import '../gameplay.dart';
import '../gameplay_bindings.dart';
import '../gameplay_packs.dart';
import '../import_report.dart';
import '../io/authoring_text.dart';
import '../io/gameplay_pack_codec.dart';
import '../llm/tool_usage.dart';
import '../tools.dart';
import '../worldinfo/world_info.dart';

part 'tool_store.dart';
part 'authoring_store.dart';
part 'authoring_authority_store.dart';
part 'authoring_run_store.dart';
part 'authoring_seed_store.dart';
part 'gameplay_pack_store.dart';
part 'gameplay_snapshot_store.dart';
part 'gameplay_binding_store.dart';

// Mark only persisted ancestor-path damage while preserving legacy StateError semantics.
class _StoredAncestorDataError extends StateError {
  _StoredAncestorDataError(super.message);
}

/// The chat settings and original ST metadata, separate from the selected path.
/// JSON values returned by the store are detached copies.
class StoredChat {
  const StoredChat({
    required this.id,
    required this.characterId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.metadata,
    required this.variables,
    required this.settings,
    this.personaId,
    this.presetId,
    this.currentLeafId,
    this.selectedRootId,
  });

  final String id;
  final String characterId;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? personaId;
  final String? presetId;
  final String? currentLeafId;
  final String? selectedRootId;
  final Map<String, Object?> metadata;
  final Map<String, Object?> variables;
  final Map<String, Object?> settings;
}

/// The fields needed by tree/JSONL import and export but not by the chat canvas.
class StoredNode {
  const StoredNode({
    required this.message,
    required this.depth,
    required this.extra,
    required this.original,
    this.selectedChildId,
  });

  final TavernMessage message;
  final int depth;
  final String? selectedChildId;
  final Map<String, Object?> extra;

  /// Original ST message fields not represented by [TavernMessage]. Exporters
  /// overlay the current known fields instead of discarding unknown fields.
  final Map<String, Object?> original;
}

/// A validated node in one newly imported tree, ordered after its parent.
/// The importer owns these JSON values through the synchronous batch write.
class StoredChatImportNode {
  const StoredChatImportNode({
    required this.key,
    required this.parentKey,
    required this.role,
    required this.speaker,
    required this.text,
    required this.at,
    required this.hidden,
    required this.state,
    required this.extra,
    required this.original,
    this.reasoning,
    this.speakerCharacterId,
    this.usage,
  });

  final String key;
  final String? parentKey;
  final TavernRole role;
  final String speaker;
  final String text;
  final String? reasoning;
  final String? speakerCharacterId;
  final DateTime at;
  final bool hidden;
  final TavernUsage? usage;
  final Map<String, Object?> state;
  final Map<String, Object?> extra;
  final Map<String, Object?> original;
}

/// The finite history inputs consumed by display macros. All nodes are
/// detached display projections, without inspection or original body copies.
class StoredDisplayHistory {
  const StoredDisplayHistory({required this.length, this.last, this.user, this.character, this.previousUser});
  final int length;
  final StoredNode? last;
  final StoredNode? user;
  final StoredNode? character;
  final StoredNode? previousUser;
}

class _NodeExtraProjection {
  const _NodeExtraProjection(this.raw, this.reportedUsage, this.displayContext);
  final String raw;
  final String? reportedUsage;
  final String displayContext;
}

/// The ancestry needed by prompt admission and rollback, without old bodies,
/// inspections or complete imported message documents.
class StoredHistoryLink {
  const StoredHistoryLink({
    required this.nodeId,
    required this.role,
    required this.speaker,
    required this.hidden,
    required this.isSystem,
    this.selectedChildId,
    this.speakerCharacterId,
    this.seq = 0,
    this.sourceEpoch = 0,
    this.contentVersion = 0,
  });
  final String nodeId;
  final int seq, sourceEpoch, contentVersion;
  final String? selectedChildId, speakerCharacterId;
  final TavernRole role;
  final String speaker;
  final bool hidden;
  final bool isSystem;
}

/// Identity-only graph used while preparing a structural bridge transaction.
/// Message bodies and full states are read only for pages the plan changes.
class StoredTreeLink {
  const StoredTreeLink({
    required this.nodeId,
    required this.parentId,
    required this.selectedChildId,
    required this.sequence,
    required this.deleted,
  });
  final String nodeId;
  final String? parentId;
  final String? selectedChildId;
  final int sequence;
  final bool deleted;
}

/// A saved preset and its original import text. JSON returned by the store is
/// detached; execution uses [raw], never the archived [sourceText].
class StoredPreset {
  const StoredPreset({
    required this.id,
    required this.name,
    required this.sourceText,
    required this.raw,
    required this.createdAt,
    required this.updatedAt,
    this.envelope,
    this.importReport,
  });

  final String id;
  final String name;
  final String sourceText;
  final Map<String, Object?> raw;
  final Map<String, Object?>? envelope;
  final TavernImportReport? importReport;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// Library metadata only. Listing presets does not load or decode their JSON.
class StoredPresetSummary {
  const StoredPresetSummary({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.hasEnvelope,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool hasEnvelope;
}

/// One tool invocation or explicit user edit. JSON is snapshotted at
/// construction and every read is detached. A null nodeId is an unanchored
/// audit record, never an alias for the chat's current leaf.
class StoredAgentRun {
  StoredAgentRun({
    required this.id,
    required this.chatId,
    this.nodeId,
    required this.kind,
    required this.at,
    Map<String, Object?>? usage,
    required Map<String, Object?> result,
  }) : _usage = usage == null ? null : jsonEncode(usage),
       _result = jsonEncode(result);

  final String id;
  final String chatId;
  final String? nodeId;
  final String kind;
  final DateTime at;
  final String? _usage;
  final String _result;

  Map<String, Object?>? get usage => _usage == null ? null : jsonDecode(_usage) as Map<String, Object?>;
  Map<String, Object?> get result => jsonDecode(_result) as Map<String, Object?>;
}

/// The SQLite owner. Methods are synchronous so a tree edit and its remembered
/// path cannot be interleaved by a streaming callback on this isolate.
///
/// Only committed writes emit [changes]. The Tavern facade owns subscriptions
/// and combines these notifications with the character-file library.
class ChatStore {
  ChatStore._(this._db, {DateTime Function()? clock, String Function()? createId})
    : _clock = clock ?? DateTime.now,
      _createId = createId ?? _newId {
    try {
      _initialize();
    } catch (_) {
      _db.close();
      rethrow;
    }
  }

  factory ChatStore.open(String path, {DateTime Function()? clock, String Function()? createId}) {
    File(path).parent.createSync(recursive: true);
    return ChatStore._(sqlite3.open(path), clock: clock, createId: createId);
  }

  factory ChatStore.inMemory({DateTime Function()? clock, String Function()? createId}) {
    return ChatStore._(sqlite3.openInMemory(), clock: clock, createId: createId);
  }

  /// Takes ownership of an open connection, including closing it on failure.
  /// The connection must not have an active transaction. Callers must not run
  /// independent transactions on it while the store is open. This also permits
  /// SQLite configuration and fault injection in integration tests.
  factory ChatStore.fromDatabase(Database database, {DateTime Function()? clock, String Function()? createId}) {
    return ChatStore._(database, clock: clock, createId: createId);
  }

  static const schemaVersion = 17;

  // Keys are destination versions. Future upgrades register every successor
  // here and increase schemaVersion; no existing schema is dropped or replayed.
  // Steps run inside one transaction and must not manage transactions themselves.
  static const _schemaMigrations = <int, String>{
    1: _schemaV1,
    2: _schemaV2,
    3: _schemaV3,
    4: _schemaV4,
    5: _schemaV5,
    6: _schemaV6,
    7: _schemaV7,
    8: _schemaV8,
    9: _schemaV9,
    10: _schemaV10,
    11: _schemaV11,
    12: _schemaV12,
    13: _gameplayPackSchema,
    14: _gameplayBindingSchema,
    15: _gameplayWorldInfoPolicySchema,
    16: _gameplayCastImportsSchema,
    17: _authoringPayloadSchema,
  };
  static const _schemaV12 = '$_authoringRunSchema\n$_authoringSeedSchema';
  final Database _db;
  final DateTime Function() _clock;
  final String Function() _createId;
  final _changes = StreamController<String>.broadcast();
  final _chatCommits = StreamController<({String chatId, bool bodyOnly})>.broadcast();
  final _presetChanges = StreamController<void>.broadcast();
  final _changedChats = <String>{};
  final _displayVersions = <String, Object>{};
  Object _presetVersion = Object();

  /// Committed preset-library identity; unchanged by ordinary chat writes.
  Object get presetVersion => _transactionDepth == 0 ? _presetVersion : Object();
  var _presetsChanged = false;
  var _transactionDepth = 0;
  ({Object error, StackTrace stackTrace})? _transactionFailure;
  var _closed = false;
  var _streamingWriters = 0;
  var _synchronous = 2;

  /// Internal synchronous publication after an outer COMMIT and its memory
  /// adoption, before asynchronous change notifications. The observer may read
  /// registered targets; it must not throw, await, write SQL or call a host.
  /// Rollbacks and nested savepoint releases never invoke it.
  /// Pure streaming-body checkpoints skip it, but still publish [changes].
  void Function(Set<String> chatIds, bool presetsChanged)? committedObserver;

  Stream<String> get changes => _changes.stream;

  /// The same committed chat changes with their original transaction kind.
  /// Body checkpoints are separate outer transactions and only update text.
  Stream<({String chatId, bool bodyOnly})> get chatCommits => _chatCommits.stream;

  /// Preset records and selections changed in a committed outer transaction.
  /// Several edits in one transaction emit once; rolled-back edits never emit.
  Stream<void> get presetChanges => _presetChanges.stream;

  void _initialize() {
    if (!_db.autocommit) {
      throw ArgumentError('ChatStore requires a connection without an active transaction.');
    }
    final version = _db.select('PRAGMA user_version').first['user_version'] as int;
    // Reject unsupported versions or an incomplete migration registry before
    // persistent configuration such as journal_mode can alter the database.
    final plan = _migrationPlan(version);
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA busy_timeout = 5000');
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = FULL');
    if (plan.isNotEmpty) {
      transaction(() {
        // Another connection may have upgraded while BEGIN IMMEDIATE waited.
        // Build the executable plan from the version under the acquired lock.
        final lockedVersion = _db.select('PRAGMA user_version').first['user_version'] as int;
        for (final step in _migrationPlan(lockedVersion)) {
          _db.execute(step.sql);
          _db.execute('PRAGMA user_version = ${step.version}');
        }
      });
    }
    _recoverPendingNodes();
  }

  // A process can stop between a body checkpoint and the terminal transaction.
  // The indexed text is still the old committed text, so this promotion uses
  // the unchanged FTS trigger's correct OLD values. Do not attach a previous
  // continuation's completed inspection or usage to a recovered partial body.
  void _recoverPendingNodes() {
    if (_db.select('SELECT 1 FROM nodes WHERE stream_text IS NOT NULL OR deleted_by IS NOT NULL LIMIT 1').isEmpty &&
        _db.select('SELECT 1 FROM deleted_subtrees LIMIT 1').isEmpty &&
        !hasPendingToolRecords()) {
      return;
    }
    transaction(() {
      recoverToolRecords();
      // Undo belongs to the previous open session. Every physical descendant
      // was marked, including descendants with an older deletion token.
      _db.execute('DELETE FROM nodes WHERE deleted_by IS NOT NULL');
      _db.execute('DELETE FROM deleted_subtrees');
      _db.execute(r'''UPDATE chats SET metadata = json_remove(metadata, '$.dshgo.latestInspection')
        WHERE EXISTS (SELECT 1 FROM nodes n WHERE n.chat_id = chats.id AND n.stream_text IS NOT NULL
          AND n.id = json_extract(chats.metadata, '$.dshgo.latestInspection.nodeId'))''');
      _db.execute(r'''UPDATE nodes SET text = stream_text, reasoning = stream_reasoning,
        usage = NULL, reported_usage = NULL, extra = json_remove(extra, '$.dshgo.inspection'),
        stream_text = NULL, stream_reasoning = NULL WHERE stream_text IS NOT NULL''');
    });
  }

  /// Stream checkpoints use WAL NORMAL. The setting is connection-wide, so
  /// concurrent turns share a reference count and the final one restores FULL.
  /// Call outside a transaction and pair with [endStreamingWrites] in finally.
  void beginStreamingWrites() {
    _outsideTransaction();
    if (_streamingWriters == 0) _setSynchronous(1);
    _streamingWriters++;
  }

  void endStreamingWrites() {
    _outsideTransaction();
    if (_streamingWriters == 0) throw StateError('There is no active streaming writer.');
    _streamingWriters--;
    if (_streamingWriters == 0) _setSynchronous(2);
  }

  T _withDurability<T>(int level, T Function() operation, {void Function()? onCommitted, bool bodyOnly = false}) {
    _outsideTransaction();
    _setSynchronous(level);
    try {
      return _transaction(operation, onCommitted: onCommitted, bodyOnly: bodyOnly);
    } finally {
      if (_streamingWriters == 0) {
        _setSynchronous(2);
      } else {
        try {
          _setSynchronous(1);
        } on SqliteException {
          // Restoring this optimization failed after COMMIT/ROLLBACK. Keep
          // the stronger FULL setting; never misreport an already committed
          // write or replace the operation's original error. The next body
          // checkpoint explicitly retries NORMAL before its own transaction.
        }
      }
    }
  }

  void _outsideTransaction() {
    _ensureOpen();
    if (_transactionDepth != 0 || !_db.autocommit) {
      throw StateError('Changing streaming durability requires no active transaction.');
    }
  }

  void _setSynchronous(int value) {
    if (_synchronous == value) return;
    _db.execute('PRAGMA synchronous = $value');
    _synchronous = value;
  }

  static List<({int version, String sql})> _migrationPlan(int version) {
    if (version < 0) {
      throw StateError('Invalid tavern database schema version: $version.');
    }
    if (version > schemaVersion) {
      throw StateError('This tavern database uses schema $version; supported version is $schemaVersion.');
    }
    final steps = <({int version, String sql})>[];
    for (var next = version + 1; next <= schemaVersion; next++) {
      final sql = _schemaMigrations[next];
      if (sql == null) {
        throw StateError('Missing tavern schema migration from ${next - 1} to $next.');
      }
      steps.add((version: next, sql: sql));
    }
    return steps;
  }

  /// Batches synchronous operations atomically. Nested calls use savepoints;
  /// catching a failed nested operation does not retain half of that operation.
  /// If SQLite aborts the entire transaction, every enclosing batch must fail.
  /// Future-returning callbacks are rejected before invocation when their type
  /// is identifiable. Only synchronous callbacks are supported: this method
  /// cannot cancel asynchronous work a callback schedules or hides behind a
  /// dynamic return type.
  /// [onCommitted] is an internal synchronous adoption hook for an outer
  /// transaction. Prepare its objects first: it must only assign references,
  /// before notifications or durability restoration can throw after COMMIT.
  /// Nested hooks and identifiable Future-returning hooks are rejected before
  /// the operation starts.
  T transaction<T>(T Function() operation, {void Function()? onCommitted}) {
    // Only body checkpoints use NORMAL. A different chat's ordinary edits,
    // settings, rollback and terminal saves retain FULL while streams wait.
    if (_transactionDepth > 0) {
      if (onCommitted != null) throw StateError('A savepoint cannot announce a durable commit.');
      return _transaction(operation);
    }
    if (onCommitted is Future<dynamic> Function()) {
      throw ArgumentError('ChatStore.transaction requires a synchronous onCommitted hook.');
    }
    return _withDurability(2, operation, onCommitted: onCommitted);
  }

  T _transaction<T>(T Function() operation, {void Function()? onCommitted, bool bodyOnly = false}) {
    _ensureOpen();
    _checkTransactionState();
    if (operation is Future<dynamic> Function()) {
      throw ArgumentError('ChatStore.transaction requires a synchronous callback.');
    }
    final depth = _transactionDepth;
    final previousChanges = Set<String>.of(_changedChats);
    final previousPresetChanges = _presetsChanged;
    final savepoint = 'tavern_$depth';
    var started = false;
    var completed = false;
    late T value;
    try {
      _db.execute(depth == 0 ? 'BEGIN IMMEDIATE' : 'SAVEPOINT $savepoint');
      started = true;
      _transactionDepth = depth + 1;
      value = operation();
      if (value is Future<dynamic>) {
        // A callback with an erased return type may already have started.
        // Observe its eventual error, while rejecting the unsupported result.
        value.ignore();
        throw ArgumentError('ChatStore.transaction requires a synchronous callback.');
      }
      _checkTransactionState();
      _db.execute(depth == 0 ? 'COMMIT' : 'RELEASE SAVEPOINT $savepoint');
      completed = true;
      // Invalidate before callbacks can re-enter a display read or throw after
      // the successful COMMIT. Streaming bodies change the same read view.
      if (depth == 0) {
        if (_presetsChanged) {
          _presetVersion = Object();
          _displayVersions.clear();
        } else {
          for (final chatId in _changedChats) {
            _displayVersions.remove(chatId);
          }
        }
      }
      onCommitted?.call();
    } catch (error, stackTrace) {
      try {
        // FULL/IOERR can make SQLite roll back without another SQL statement.
        // In that case there are no remaining savepoints to roll back to.
        if (started && !_db.autocommit) {
          if (depth == 0 || _transactionFailure != null) {
            _db.execute('ROLLBACK');
          } else {
            _db.execute('ROLLBACK TO SAVEPOINT $savepoint');
            _db.execute('RELEASE SAVEPOINT $savepoint');
          }
        }
        if (depth > 0 && _db.autocommit) {
          _transactionFailure ??= (error: error, stackTrace: stackTrace);
        }
      } catch (_) {
        // Cleanup failure must neither replace the original exception nor let
        // an enclosing batch continue after losing its atomicity.
        _transactionFailure ??= (error: error, stackTrace: stackTrace);
      }
      rethrow;
    } finally {
      _transactionDepth = depth;
      if (!completed) {
        _changedChats.clear();
        _presetsChanged = false;
        if (depth > 0 && _transactionFailure == null) {
          _changedChats.addAll(previousChanges);
          _presetsChanged = previousPresetChanges;
        }
      }
      if (depth == 0) _transactionFailure = null;
    }
    if (depth == 0) {
      final changed = List<String>.of(_changedChats);
      final presetsChanged = _presetsChanged;
      _changedChats.clear();
      _presetsChanged = false;
      // Only writeStreamingBody opts out, in its isolated transaction. It
      // cannot change a registered variable/preparation carrier; ordinary
      // commits still observe after onCommitted has adopted their runtime.
      if (!bodyOnly) {
        committedObserver?.call(Set<String>.unmodifiable(changed), presetsChanged);
      }
      for (final chatId in changed) {
        _changes.add(chatId);
        _chatCommits.add((chatId: chatId, bodyOnly: bodyOnly));
      }
      if (presetsChanged) {
        _presetChanges.add(null);
      }
    }
    return value;
  }

  void _checkTransactionState() {
    final failure = _transactionFailure;
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
    if (_transactionDepth > 0 && _db.autocommit) {
      throw StateError('SQLite aborted the enclosing chat transaction.');
    }
  }

  /// Saves already parsed JSON. Import validation and envelope/raw agreement
  /// belong to the codec; both documents commit with the original text here.
  StoredPreset createPreset({
    required String name,
    required String sourceText,
    required Map<String, Object?> raw,
    Map<String, Object?>? envelope,
    TavernImportReport? importReport,
  }) => transaction(() {
    final id = _createId();
    final at = _clock().millisecondsSinceEpoch;
    _db.execute(
      '''INSERT INTO presets (id, name, source_text, raw_json, envelope_json, import_report_json, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        name,
        sourceText,
        jsonEncode(raw),
        envelope == null ? null : jsonEncode(envelope),
        importReport == null ? null : jsonEncode(importReport.toJson()),
        at,
        at,
      ],
    );
    _presetsChanged = true;
    return preset(id)!;
  });

  StoredPreset? preset(String id) {
    _ensureOpen();
    final rows = _db.select(
      '''SELECT id, char(1) || name AS name, char(1) || source_text AS guarded_source_text,
                raw_json, envelope_json, import_report_json, created_at, updated_at
         FROM presets WHERE id = ?''',
      [id],
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.single;
    return StoredPreset(
      id: row['id'] as String,
      name: _unguardText(row['name'])!,
      sourceText: _unguardText(row['guarded_source_text'])!,
      raw: _map(row['raw_json']),
      envelope: row['envelope_json'] == null ? null : _map(row['envelope_json']),
      importReport: row['import_report_json'] == null
          ? null
          : TavernImportReport.fromJson(_map(row['import_report_json'])),
      createdAt: _date(row['created_at']),
      updatedAt: _date(row['updated_at']),
    );
  }

  List<StoredPresetSummary> listPresets() {
    _ensureOpen();
    final rows = _db.select(
      '''SELECT id, char(1) || name AS name, created_at, updated_at, envelope_json IS NOT NULL AS has_envelope
         FROM presets ORDER BY updated_at DESC, id''',
    );
    return [
      for (final row in rows)
        StoredPresetSummary(
          id: row['id'] as String,
          name: _unguardText(row['name'])!,
          createdAt: _date(row['created_at']),
          updatedAt: _date(row['updated_at']),
          hasEnvelope: row['has_envelope'] == 1,
        ),
    ];
  }

  /// Replaces the editable documents together, retaining source_text and the
  /// original creation time. The caller merges only its intended fields.
  StoredPreset updatePreset(
    String id, {
    required String name,
    required Map<String, Object?> raw,
    required Map<String, Object?>? envelope,
  }) => transaction(() {
    _requirePreset(id);
    _db.execute(
      '''UPDATE presets SET name = ?, raw_json = ?, envelope_json = ?, updated_at = ? WHERE id = ?''',
      [name, jsonEncode(raw), envelope == null ? null : jsonEncode(envelope), _clock().millisecondsSinceEpoch, id],
    );
    _presetsChanged = true;
    return preset(id)!;
  });

  /// Refreshes only the capability snapshot. The editable data, original text,
  /// selection, creation time and content update time remain unchanged.
  void savePresetImportReport(String id, TavernImportReport report) => transaction(() {
    _requirePreset(id);
    if (report.kind != TavernImportKind.preset) throw ArgumentError('Expected a preset import report.');
    _db.execute('UPDATE presets SET import_report_json = ? WHERE id = ?', [jsonEncode(report.toJson()), id]);
    _presetsChanged = true;
  });

  String? get defaultPresetId {
    _ensureOpen();
    return _db
            .select('SELECT default_preset_id FROM preset_preferences WHERE singleton = 1')
            .single['default_preset_id']
        as String?;
  }

  /// Null clears the library default. It does not rewrite chat bindings.
  void setDefaultPreset(String? id) => transaction(() {
    if (id != null) {
      _requirePreset(id);
    }
    if (defaultPresetId == id) {
      return;
    }
    _db.execute('UPDATE preset_preferences SET default_preset_id = ? WHERE singleton = 1', [id]);
    _presetsChanged = true;
  });

  /// Changes only the binding. The facade handles active-turn barriers and
  /// any deliberate removal of a legacy settings.preset in the same batch.
  void bindPreset(String chatId, String? id) => transaction(() {
    final row = _chatRow(chatId);
    if (id != null) {
      _requirePreset(id);
    }
    if (row['preset_id'] == id) {
      return;
    }
    _db.execute('UPDATE chats SET preset_id = ? WHERE id = ?', [id, chatId]);
    _touch(chatId);
    _presetsChanged = true;
  });

  List<String> chatsBoundToPreset(String id) {
    _ensureOpen();
    return [
      for (final row in _db.select('SELECT id FROM chats WHERE preset_id = ? ORDER BY id', [id])) row['id'] as String,
    ];
  }

  /// Atomically clears the bindings/default and deletes the record. The return
  /// value reports whether a record existed; stale legacy bindings are cleaned
  /// even if it did not. The facade drains affected turns before calling this.
  bool deletePreset(String id) => transaction(() {
    final existed = _db.select('SELECT 1 FROM presets WHERE id = ?', [id]).isNotEmpty;
    final chats = chatsBoundToPreset(id);
    final wasDefault = defaultPresetId == id;
    if (!existed && chats.isEmpty && !wasDefault) {
      return false;
    }
    if (chats.isNotEmpty) {
      _db.execute('UPDATE chats SET preset_id = NULL, updated_at = ? WHERE preset_id = ?', [
        _clock().millisecondsSinceEpoch,
        id,
      ]);
      _changedChats.addAll(chats);
    }
    if (wasDefault) {
      _db.execute('UPDATE preset_preferences SET default_preset_id = NULL WHERE singleton = 1');
    }
    _db.execute('DELETE FROM presets WHERE id = ?', [id]);
    _presetsChanged = true;
    return existed;
  });

  void _requirePreset(String id) {
    if (_db.select('SELECT 1 FROM presets WHERE id = ?', [id]).isEmpty) {
      throw StateError('Preset not found: $id');
    }
  }

  /// Uses the ordinary nested transaction contract, so terminal state, own
  /// node audit and these records can share one caller-owned SQL commit.
  /// Audit writes do not change the selected path, revision or notifications.
  void writeAgentRun(StoredAgentRun run) => transaction(() {
    _chatRow(run.chatId);
    final nodeId = run.nodeId;
    if (nodeId != null) {
      // A soft-deleted node remains a valid physical audit anchor. The FK
      // alone cannot enforce that the referenced node belongs to this chat.
      _nodeRow(run.chatId, nodeId, includeDeleted: true);
    }
    _db.execute(
      '''INSERT INTO agent_runs (id, chat_id, node_id, kind, at, usage, result_json)
         VALUES (?, ?, ?, ?, ?, ?, ?)''',
      [run.id, run.chatId, nodeId, run.kind, run.at.millisecondsSinceEpoch, run._usage, run._result],
    );
  });

  /// Omitted nodeId reads the complete chat audit, including unanchored runs.
  /// An explicit id matches only that physical anchor; null records are not
  /// reassigned to the current branch. Equal timestamps put newer inserts first.
  List<StoredAgentRun> agentRuns(String chatId, {String? nodeId, int limit = 50}) {
    _chatRow(chatId);
    if (limit < 0) {
      throw ArgumentError.value(limit, 'limit', 'Must be non-negative.');
    }
    if (limit == 0) {
      return [];
    }
    final rows = _db.select(
      '''SELECT id, chat_id, node_id, kind, at, usage, result_json FROM agent_runs
         WHERE chat_id = ? AND (? IS NULL OR node_id = ?)
         ORDER BY at DESC, rowid DESC LIMIT ?''',
      [chatId, nodeId, nodeId, limit],
    );
    return [
      for (final row in rows)
        StoredAgentRun(
          id: row['id'] as String,
          chatId: row['chat_id'] as String,
          nodeId: row['node_id'] as String?,
          kind: row['kind'] as String,
          at: _date(row['at']),
          usage: row['usage'] == null ? null : _map(row['usage']),
          result: _map(row['result_json']),
        ),
    ];
  }

  /// Director queries use publication order, independent of clock changes or
  /// interleaved state tools. The existing general audit ordering is unchanged.
  List<StoredAgentRun> agentRunsByKind(String chatId, Set<String> kinds, {int limit = 50, String? beforeId}) {
    _chatRow(chatId);
    if (limit < 0) throw ArgumentError.value(limit, 'limit', 'Must be non-negative.');
    if (kinds.isEmpty || limit == 0) return [];
    final values = kinds.toList(growable: false);
    final slots = List.filled(values.length, '?').join(',');
    int? before;
    if (beforeId != null) {
      final anchor = _db.select('SELECT rowid FROM agent_runs WHERE chat_id = ? AND id = ? AND kind IN ($slots)', [
        chatId,
        beforeId,
        ...values,
      ]);
      if (anchor.isEmpty) throw StateError('Agent run cursor not found in this chat and kind.');
      before = anchor.single['rowid'] as int;
    }
    final List<Row> rows;
    if (values.length == 1) {
      rows = _agentRunRowsByKind(chatId, values.single, limit, before);
    } else {
      // A row below the first N of its own kind cannot be in the global first
      // N. Merge raw rows before decoding so excluded malformed documents do
      // not become observable, and bad selected rows still occupy their slot.
      final candidates = <Row>[for (final kind in values) ..._agentRunRowsByKind(chatId, kind, limit, before)];
      candidates.sort((left, right) => (right['rowid'] as int).compareTo(left['rowid'] as int));
      rows = candidates.take(limit).toList();
    }
    return [for (final row in rows) _directorStoredRun(row)];
  }

  List<Row> _agentRunRowsByKind(String chatId, String kind, int limit, int? before) {
    final cursor = before == null ? '' : ' AND rowid < ?';
    return _db.select(
      '''SELECT rowid, id, chat_id, node_id, kind, at, usage, result_json
      FROM agent_runs WHERE chat_id = ? AND kind = ?$cursor
      ORDER BY rowid DESC LIMIT ?''',
      [chatId, kind, ?before, limit],
    );
  }

  /// Exact persisted identity, independent of a pagination window or newer
  /// publications. Foreign-chat ids return null; malformed JSON stays inert.
  StoredAgentRun? agentRunById(String chatId, String id) {
    _chatRow(chatId);
    final rows = _db.select(
      '''SELECT id, chat_id, node_id, kind, at, usage, result_json
      FROM agent_runs WHERE chat_id = ? AND id = ?''',
      [chatId, id],
    );
    return rows.isEmpty ? null : _directorStoredRun(rows.single);
  }

  StoredAgentRun _directorStoredRun(Row row) {
    try {
      return StoredAgentRun(
        id: row['id'] as String,
        chatId: row['chat_id'] as String,
        nodeId: row['node_id'] as String?,
        kind: row['kind'] as String,
        at: _date(row['at']),
        usage: row['usage'] == null ? null : _map(row['usage']),
        result: _map(row['result_json']),
      );
    } catch (_) {
      // Preserve the bad bytes on disk. A caller can show this row as
      // unavailable without treating it as a valid empty director result.
      // Construction also encodes a private copy: an overflowing JSON number
      // may decode to Infinity yet fail that encoding. Isolate the whole row.
      return StoredAgentRun(
        id: row['id'] as String,
        chatId: row['chat_id'] as String,
        nodeId: row['node_id'] as String?,
        kind: row['kind'] as String,
        at: _date(row['at']),
        result: {'version': 0, 'unavailable': 'invalid_saved_director_json'},
      );
    }
  }

  /// Existing summaries only; both endpoints must belong to this ordered
  /// source path. No summary is generated or rewritten by a director read.
  List<Map<String, Object?>> directorSummaries(String chatId, List<String> path, {int limit = 20}) {
    _chatRow(chatId);
    if (limit < 0) throw ArgumentError.value(limit, 'limit', 'Must be non-negative.');
    if (limit == 0) return [];
    final positions = {for (var i = 0; i < path.length; i++) path[i]: i};
    final result = <Map<String, Object?>>[];
    for (final row in _db.select(
      'SELECT id, from_node_id, to_node_id, text FROM summaries WHERE chat_id = ? ORDER BY rowid DESC',
      [chatId],
    )) {
      final first = positions[row['from_node_id']];
      final last = positions[row['to_node_id']];
      if (first == null || last == null || first > last) continue;
      result.add({
        'id': row['id'],
        'fromNodeId': row['from_node_id'],
        'toNodeId': row['to_node_id'],
        'text': row['text'],
      });
      if (result.length == limit) break;
    }
    return result.reversed.toList(growable: false);
  }

  /// Chat-owned raw memory entries. Invalid JSON remains preserved and is
  /// reported by the adapter instead of being repaired during a read.
  List<({String id, Map<String, Object?> entry, bool valid})> directorMemories(String chatId) {
    _chatRow(chatId);
    final result = <({String id, Map<String, Object?> entry, bool valid})>[];
    for (final row in _db.select(
      "SELECT id, entry_json FROM memories WHERE chat_id = ? AND origin = 'legacy' ORDER BY rowid",
      [chatId],
    )) {
      try {
        final entry = _map(row['entry_json']);
        // The adapter/WorldInfoBook must be able to copy the complete native
        // document, including unknown fields. Do not repair non-finite values.
        jsonEncode(entry);
        result.add((id: row['id'] as String, entry: entry, valid: true));
      } catch (_) {
        result.add((id: row['id'] as String, entry: <String, Object?>{}, valid: false));
      }
    }
    return result;
  }

  String createChat({
    required String characterId,
    String title = '',
    String? id,
    String? personaId,
    String? presetId,
    Map<String, Object?> metadata = const {},
    Map<String, Object?> variables = const {},
    Map<String, Object?> settings = const {},
  }) {
    return transaction(() {
      final chatId = id ?? _createId();
      final at = _clock().millisecondsSinceEpoch;
      _db.execute(
        '''INSERT INTO chats
           (id, character_id, title, created_at, updated_at, persona_id, preset_id, metadata, variables, settings)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          chatId,
          characterId,
          title,
          at,
          at,
          personaId,
          presetId,
          jsonEncode(metadata),
          jsonEncode(variables),
          jsonEncode(settings),
        ],
      );
      _changedChats.add(chatId);
      return chatId;
    });
  }

  StoredChat chat(String chatId) {
    final row = _chatRow(chatId);
    return StoredChat(
      id: row['id'] as String,
      characterId: row['character_id'] as String,
      title: _unguardText(row['title'])!,
      createdAt: _date(row['created_at']),
      updatedAt: _date(row['updated_at']),
      personaId: row['persona_id'] as String?,
      presetId: row['preset_id'] as String?,
      currentLeafId: row['current_leaf_id'] as String?,
      selectedRootId: row['selected_root_id'] as String?,
      metadata: _map(row['metadata']),
      variables: _map(row['variables']),
      settings: _map(row['settings']),
    );
  }

  /// Revision of the committed tree/content/state view. Bridge tokens add an
  /// engine epoch; this integer is never exposed to JavaScript as a Number.
  int treeRevision(String chatId) => _chatRow(chatId, columns: 'c.tree_revision')['tree_revision'] as int;

  /// Current host identity without materializing the chat's JSON documents.
  /// This is a fresh SQL read, including inside a managed transaction.
  String chatCharacterId(String chatId) => _chatRow(chatId, columns: 'c.character_id')['character_id'] as String;

  /// Current selection without materializing the chat's JSON documents.
  String? chatCurrentLeafId(String chatId) =>
      _chatRow(chatId, columns: 'c.current_leaf_id')['current_leaf_id'] as String?;

  /// Detached variables from the real carrier, without decoding chat metadata.
  Map<String, Object?> chatVariables(String chatId) => _map(_chatRow(chatId, columns: 'c.variables')['variables']);

  /// Allocates an identity without adding a row. A batch can prepare all state
  /// reports against their actual node ids before its first INSERT.
  String newNodeId() {
    _ensureOpen();
    return _createId();
  }

  /// A group keeps its real host in chats.character_id. Library existence is
  /// projected by the engine; the SQL roster never guesses a card by name.
  TavernGroupChat? groupChat(String chatId) {
    _ensureOpen();
    final rows = _db.select(
      '''SELECT g.*, c.character_id, char(1) || c.title AS title
      FROM group_chats g JOIN chats c ON c.id = g.chat_id WHERE g.chat_id = ?''',
      [chatId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return TavernGroupChat(
      chatId: chatId,
      title: _unguardText(row['title'])!,
      hostCharacterId: row['character_id'] as String,
      activation: TavernGroupActivation.values.byName(row['activation'] as String),
      maxSpeakersPerTurn: row['max_speakers'] as int,
      allowSelfResponses: row['allow_self_responses'] == 1,
      members: [
        for (final member in _db.select('SELECT * FROM group_members WHERE chat_id = ? ORDER BY position', [chatId]))
          TavernGroupMember(
            characterId: member['character_id'] as String,
            talkativeness: (member['talkativeness'] as num).toDouble(),
            muted: member['muted'] == 1,
            modelRole: TavernGroupModelRole.values.byName(member['model_role'] as String),
          ),
      ],
    );
  }

  void saveGroup(TavernGroupChat group) {
    transaction(() {
      final chat = _chatRow(group.chatId);
      if (chat['character_id'] != group.hostCharacterId) throw StateError('A group host cannot be rebound.');
      _db.execute(
        '''INSERT INTO group_chats (chat_id, activation, max_speakers, allow_self_responses)
        VALUES (?, ?, ?, ?) ON CONFLICT(chat_id) DO UPDATE SET
        activation = excluded.activation, max_speakers = excluded.max_speakers,
        allow_self_responses = excluded.allow_self_responses''',
        [group.chatId, group.activation.name, group.maxSpeakersPerTurn, group.allowSelfResponses ? 1 : 0],
      );
      _db.execute('DELETE FROM group_members WHERE chat_id = ?', [group.chatId]);
      for (var index = 0; index < group.members.length; index++) {
        final member = group.members[index];
        _db.execute(
          '''INSERT INTO group_members
          (chat_id, character_id, position, talkativeness, muted, model_role) VALUES (?, ?, ?, ?, ?, ?)''',
          [group.chatId, member.characterId, index, member.talkativeness, member.muted ? 1 : 0, member.modelRole.name],
        );
      }
      updateChat(group.chatId, title: group.title);
    });
  }

  Map<String, Object?> groupInitialState(String chatId) {
    final rows = _db.select('SELECT initial_state FROM group_chats WHERE chat_id = ?', [chatId]);
    return rows.isEmpty ? <String, Object?>{} : _map(rows.single['initial_state']);
  }

  void setGroupInitialState(String chatId, Map<String, Object?> state) {
    transaction(() {
      if (groupChat(chatId) == null) throw StateError('Group not found: $chatId');
      _db.execute('UPDATE group_chats SET initial_state = ? WHERE chat_id = ?', [jsonEncode(state), chatId]);
      _touch(chatId);
    });
  }

  List<String> groupHostChats(String characterId) => [
    for (final row in _db.select(
      '''SELECT c.id FROM chats c JOIN group_chats g ON g.chat_id = c.id
      WHERE c.character_id = ? ORDER BY c.id''',
      [characterId],
    ))
      row['id'] as String,
  ];

  void removeCharacterGroupMemberships(String characterId) {
    transaction(() {
      final affected = _db.select('SELECT chat_id FROM group_members WHERE character_id = ?', [characterId]);
      _db.execute('DELETE FROM group_members WHERE character_id = ?', [characterId]);
      for (final row in affected) {
        _touch(row['chat_id'] as String);
      }
    });
  }

  /// Explicit persona bindings in the same recency order as [listChats].
  /// Selection and cleanup do not need message bodies or chat JSON documents.
  List<({String id, String? personaId})> listChatPersonaBindings() {
    _ensureOpen();
    return [
      for (final row in _db.select('SELECT id, persona_id FROM chats ORDER BY updated_at DESC, id'))
        (id: row['id'] as String, personaId: row['persona_id'] as String?),
    ];
  }

  /// Counts and recency for the character picker without loading message text.
  Map<String, ({int count, DateTime lastAt})> characterChatStats() {
    _ensureOpen();
    return {
      for (final row in _db.select('''SELECT ids.character_id, COUNT(*) AS chat_count, MAX(c.updated_at) AS last_at
          FROM (SELECT id AS chat_id, character_id FROM chats
            UNION SELECT chat_id, character_id FROM group_members) ids
          JOIN chats c ON c.id = ids.chat_id GROUP BY ids.character_id'''))
        row['character_id'] as String: (count: row['chat_count'] as int, lastAt: _date(row['last_at'])),
    };
  }

  /// The chats taken in from a DeepSeek export, by the conversation each came
  /// from (its id in the export).
  Map<String, ({String chatId, String characterId})> deepSeekChats() {
    _ensureOpen();
    return {
      for (final row in _db.select(
        r'''SELECT id, character_id, json_extract(metadata, '$.dshgo.deepseek.sessionId') AS source
          FROM chats WHERE 'text' = json_type(metadata, '$.dshgo.deepseek.sessionId')''',
      ))
        row['source'] as String: (chatId: row['id'] as String, characterId: row['character_id'] as String),
    };
  }

  List<TavernChatSummary> listChats({String? characterId}) {
    _ensureOpen();
    final rows = _db.select(
      '''SELECT c.id, c.character_id, char(1) || c.title AS title, c.updated_at,
                char(1) || COALESCE(n.stream_text, n.text) AS last_text, COALESCE(n.depth, 0) AS message_count,
                EXISTS(SELECT 1 FROM group_chats g WHERE g.chat_id = c.id) AS is_group
         FROM chats c LEFT JOIN nodes n ON n.id = c.current_leaf_id AND n.deleted_by IS NULL
         WHERE (? IS NULL OR c.character_id = ? OR EXISTS(
           SELECT 1 FROM group_members m WHERE m.chat_id = c.id AND m.character_id = ?))
         ORDER BY c.updated_at DESC, c.id''',
      [characterId, characterId, characterId],
    );
    return [
      for (final row in rows)
        TavernChatSummary(
          id: row['id'] as String,
          characterId: row['character_id'] as String,
          title: _unguardText(row['title'])!,
          updatedAt: _date(row['updated_at']),
          lastText: _unguardText(row['last_text']),
          messageCount: row['message_count'] as int,
          kind: row['is_group'] == 1 ? TavernChatKind.group : TavernChatKind.single,
          memberCharacterIds: row['is_group'] == 1
              ? [for (final member in groupChat(row['id'] as String)!.members) member.characterId]
              : const [],
        ),
    ];
  }

  /// Replaces only the provided JSON documents. To clear a persona/preset,
  /// pass the corresponding explicit clear flag.
  void updateChat(
    String chatId, {
    String? title,
    String? personaId,
    String? presetId,
    bool clearPersona = false,
    bool clearPreset = false,
    Map<String, Object?>? metadata,
    Map<String, Object?>? variables,
    Map<String, Object?>? settings,
  }) {
    transaction(() {
      final row = _chatRow(chatId);
      _db.execute(
        '''UPDATE chats SET title = ?, persona_id = ?, preset_id = ?, metadata = ?, variables = ?, settings = ?
           WHERE id = ?''',
        [
          title ?? _unguardText(row['title']),
          clearPersona ? null : personaId ?? row['persona_id'],
          clearPreset ? null : presetId ?? row['preset_id'],
          metadata == null ? row['metadata'] : jsonEncode(metadata),
          variables == null ? row['variables'] : jsonEncode(variables),
          settings == null ? row['settings'] : jsonEncode(settings),
          chatId,
        ],
      );
      _touch(chatId);
    });
  }

  /// A null [parentId] means a root sibling, never "the current leaf". Normal
  /// turns pass [StoredChat.currentLeafId]; a regeneration passes the old
  /// message's parent. Siblings retain their insertion order across restarts.
  TavernMessage append(
    String chatId, {
    required String? parentId,
    required TavernRole role,
    required String speaker,
    required String text,
    String? id,
    String? reasoning,
    String? speakerCharacterId,
    DateTime? at,
    bool hidden = false,
    bool makeCurrent = true,
    TavernUsage? usage,
    Map<String, Object?> extra = const {},
    Map<String, Object?> original = const {},
    Map<String, Object?>? state,
  }) {
    return transaction(() {
      final chat = _chatRow(chatId);
      final parent = parentId == null ? null : _nodeRow(chatId, parentId, columns: 'n.depth');
      final depth = parent == null ? 1 : (parent['depth'] as int) + 1;
      final nodeId = id ?? _createId();
      final encodedExtra = _encodeNodeExtra(extra, chatId, nodeId);
      _db.execute(_insertNodeSql, [
        nodeId,
        chatId,
        parentId,
        depth,
        role.name,
        speaker,
        text,
        reasoning,
        (at ?? _clock()).millisecondsSinceEpoch,
        hidden ? 1 : 0,
        _encodeUsage(usage),
        encodedExtra.reportedUsage,
        encodedExtra.displayContext,
        encodedExtra.raw,
        jsonEncode(original),
        role == TavernRole.character ? speakerCharacterId : null,
      ]);
      final parentSnapshot = parentId == null ? null : _nodeStateSnapshot(chatId, parentId);
      final parentState = parentSnapshot?.state ?? <String, Object?>{};
      final currentState = state ?? parentState;
      // Reparenting can move an existing checkpoint off a multiple of 20.
      // Reuse this reconstruction's count to bound every later append as well.
      final checkpoint = depth == 1 || depth % 20 == 0 || (parentSnapshot?.deltas ?? 0) >= 19;
      _db.execute('INSERT INTO node_states (node_id, delta_json, full_json) VALUES (?, ?, ?)', [
        nodeId,
        jsonEncode(_stateDiff(parentState, currentState)),
        checkpoint ? jsonEncode(currentState) : null,
      ]);
      if (makeCurrent) {
        if (parentId != null && parentId == chat['current_leaf_id']) {
          // The common append is constant-time; do not rewrite every ancestor
          // for every token/message in a long conversation.
          _db.execute('UPDATE nodes SET selected_child_id = ? WHERE id = ?', [nodeId, parentId]);
          _db.execute('UPDATE chats SET current_leaf_id = ? WHERE id = ?', [nodeId, chatId]);
        } else {
          _activate(chatId, nodeId);
        }
      }
      _touch(chatId, tree: true);
      return message(chatId, nodeId);
    });
  }

  /// Writes an already prepared, parent-first import tree without rereading
  /// each parent or decoding a message which the importer only needs by id.
  /// The outer codec transaction still owns all trees and final selections.
  Map<String, String> appendImportedNodes(String chatId, List<StoredChatImportNode> nodes) => transaction(() {
    chatCharacterId(chatId);
    final written = <String, ({String id, int depth, Map<String, Object?> state})>{};
    final insertNode = _db.prepare(_insertNodeSql);
    try {
      final insertState = _db.prepare('INSERT INTO node_states (node_id, delta_json, full_json) VALUES (?, ?, ?)');
      try {
        int? updatedAt;
        var treeChanges = 0;
        for (final node in nodes) {
          final parent = node.parentKey == null ? null : written[node.parentKey]!;
          final depth = parent == null ? 1 : parent.depth + 1;
          final id = _createId();
          final encodedExtra = _encodeNodeExtra(node.extra, chatId, id);
          insertNode.execute([
            id,
            chatId,
            parent?.id,
            depth,
            node.role.name,
            node.speaker,
            node.text,
            node.reasoning,
            node.at.millisecondsSinceEpoch,
            node.hidden ? 1 : 0,
            _encodeUsage(node.usage),
            encodedExtra.reportedUsage,
            encodedExtra.displayContext,
            encodedExtra.raw,
            jsonEncode(node.original),
            node.role == TavernRole.character ? node.speakerCharacterId : null,
          ]);
          // All parents are new in this tree, so depth checkpoints already
          // bound the reconstruction chain to at most nineteen deltas.
          insertState.execute([
            id,
            jsonEncode(_stateDiff(parent?.state ?? const <String, Object?>{}, node.state)),
            depth == 1 || depth % 20 == 0 ? jsonEncode(node.state) : null,
          ]);
          // Preserve each clock call in its original position; only the
          // repeated update of this newly imported chat is combined.
          updatedAt = _clock().millisecondsSinceEpoch;
          treeChanges++;
          written[node.key] = (id: id, depth: depth, state: node.state);
        }
        if (updatedAt != null) {
          _touchAt(chatId, updatedAt, treeChanges: treeChanges);
        }
      } finally {
        insertState.close();
      }
    } finally {
      insertNode.close();
    }
    return {for (final entry in written.entries) entry.key: entry.value.id};
  });

  TavernMessage message(String chatId, String nodeId) => _message(_nodeRow(chatId, nodeId));

  StoredNode node(String chatId, String nodeId) => _storedNode(_nodeRow(chatId, nodeId));

  /// Detached physical extra, including inspection hidden by a stream view.
  /// Internal state transactions must preserve that raw carrier verbatim.
  Map<String, Object?> rawNodeExtra(String chatId, String nodeId) => _map(_nodeRow(chatId, nodeId)['extra']);

  /// A soft-deleted future is still a future: binding facts to a shared old
  /// source must not silently rewrite any retained descendant's provenance.
  bool hasPhysicalChildren(String chatId, String nodeId) {
    _nodeRow(chatId, nodeId);
    return _db.select('SELECT 1 FROM nodes WHERE chat_id = ? AND parent_id = ? LIMIT 1', [chatId, nodeId]).isNotEmpty;
  }

  List<StoredNode> allNodes(String chatId) {
    _chatRow(chatId);
    return [
      for (final row in _db.select(
        '''
WITH siblings AS (
  SELECT seq,
    row_number() OVER (PARTITION BY parent_id ORDER BY seq) - 1 AS sibling_index,
    count(*) OVER (
      PARTITION BY parent_id ORDER BY seq
      ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS sibling_count
  FROM nodes
  WHERE chat_id = ? AND deleted_by IS NULL
)
SELECT $_nodeColumns, s.sibling_index, s.sibling_count
FROM siblings s JOIN nodes n ON n.seq = s.seq
ORDER BY n.seq
''',
        [chatId],
      ))
        _storedNode(row),
    ];
  }

  List<StoredNode> children(String chatId, String? parentId) {
    _chatRow(chatId);
    if (parentId != null) _nodeRow(chatId, parentId);
    return [
      for (final row in _db.select(
        'SELECT $_nodeColumns, $_siblingColumns FROM nodes n WHERE n.chat_id = ? AND n.parent_id IS ? AND n.deleted_by IS NULL ORDER BY n.seq',
        [chatId, parentId],
      ))
        _storedNode(row),
    ];
  }

  /// Structural edits retain pending-deletion branches as physical children.
  /// This is deliberately separate from the visible swipe projection.
  List<StoredNode> physicalChildren(String chatId, String? parentId) {
    _chatRow(chatId);
    if (parentId != null) {
      _nodeRow(chatId, parentId, includeDeleted: true);
    }
    return [
      for (final row in _db.select(
        'SELECT $_nodeColumns, $_siblingColumns FROM nodes n WHERE n.chat_id = ? AND n.parent_id IS ? ORDER BY n.seq',
        [chatId, parentId],
      ))
        _storedNode(row),
    ];
  }

  Map<String, StoredTreeLink> treeLinks(String chatId) {
    _chatRow(chatId);
    return {
      for (final row in _db.select(
        'SELECT id, parent_id, selected_child_id, seq, deleted_by FROM nodes WHERE chat_id = ? ORDER BY seq',
        [chatId],
      ))
        row['id'] as String: StoredTreeLink(
          nodeId: row['id'] as String,
          parentId: row['parent_id'] as String?,
          selectedChildId: row['selected_child_id'] as String?,
          sequence: row['seq'] as int,
          deleted: row['deleted_by'] != null,
        ),
    };
  }

  /// Reads at most [limit] ancestors, starting at the current leaf or just
  /// before a cursor on that path. The result is always oldest first.
  List<TavernMessage> path(String chatId, {int limit = 60, String? beforeNodeId}) {
    if (limit < 0) throw ArgumentError.value(limit, 'limit', 'Must be non-negative.');
    final row = _chatRow(chatId);
    final currentLeaf = row['current_leaf_id'] as String?;
    var lastId = currentLeaf;
    if (beforeNodeId != null) {
      final before = _nodeRow(chatId, beforeNodeId);
      if (currentLeaf == null || !_isAncestor(chatId, beforeNodeId, currentLeaf)) {
        throw StateError('The page cursor is not on the current path.');
      }
      lastId = before['parent_id'] as String?;
    }
    return [for (final row in _ancestorRows(chatId, lastId, limit: limit)) _message(row)];
  }

  /// One recursive statement returns only grouped counters and path shape.
  /// Stable identities in UNION terminate a corrupt cycle without walking it
  /// in Dart or fetching message bodies, inspection, extra or state documents.
  List<TavernPathUsage> pathUsage(String chatId, {String? excludeNodeId}) {
    _ensureOpen();
    final rows = _db.select(
      '''
      WITH RECURSIVE path(id, parent_id) AS (
        SELECT n.id, n.parent_id FROM nodes n JOIN chats c ON c.current_leaf_id = n.id
          WHERE c.id = ? AND n.chat_id = c.id AND n.deleted_by IS NULL
        UNION
        SELECT n.id, n.parent_id FROM path p CROSS JOIN nodes n ON n.id = p.parent_id
          WHERE n.chat_id = ? AND n.deleted_by IS NULL
      ), totals AS (
        SELECT json_extract(n.reported_usage, '\$.model') AS model,
          (CAST(strftime('%w', coalesce(json_extract(n.reported_usage, '\$.startedAtMs'), n.at) / 1000.0,
            'unixepoch') AS INTEGER) + 6) % 7 + 1 AS utc_weekday,
          CAST(strftime('%H', coalesce(json_extract(n.reported_usage, '\$.startedAtMs'), n.at) / 1000.0,
            'unixepoch') AS INTEGER) AS utc_hour,
          sum(json_extract(n.reported_usage, '\$.promptTokens')) AS prompt_tokens,
          sum(json_extract(n.reported_usage, '\$.cacheHitTokens')) AS cache_hit_tokens,
          sum(json_extract(n.reported_usage, '\$.completionTokens')) AS completion_tokens,
          count(*) AS reply_count
        FROM path p JOIN nodes n ON n.id = p.id
        WHERE n.chat_id = ? AND n.deleted_by IS NULL AND n.role = 'character'
          AND n.stream_text IS NULL AND n.reported_usage IS NOT NULL AND n.id IS NOT ?
        GROUP BY model, utc_weekday, utc_hour
      ), shape AS (
        SELECT coalesce(sum(parent_id IS NULL), 0) AS roots FROM path
      )
      SELECT c.current_leaf_id IS NOT NULL AS has_leaf, shape.roots,
        char(1) || totals.model AS model, totals.utc_weekday, totals.utc_hour,
        totals.prompt_tokens, totals.cache_hit_tokens,
        totals.completion_tokens, totals.reply_count
      FROM chats c CROSS JOIN shape LEFT JOIN totals ON 1
      WHERE c.id = ? ORDER BY totals.model, totals.utc_weekday, totals.utc_hour
    ''',
      [chatId, chatId, chatId, excludeNodeId, chatId],
    );
    if (rows.isEmpty) throw StateError('Chat not found: $chatId');
    if (rows.first['has_leaf'] == 1 && rows.first['roots'] != 1) {
      throw _StoredAncestorDataError('The selected message path is disconnected or cyclic.');
    }
    final result = <TavernPathUsage>[];
    for (final row in rows) {
      if (row['reply_count'] == null) continue;
      result.add(
        TavernPathUsage(
          model: _unguardText(row['model']),
          utcWeekday: row['utc_weekday'] as int,
          utcHour: row['utc_hour'] as int,
          promptTokens: row['prompt_tokens'] as int,
          cacheHitTokens: row['cache_hit_tokens'] as int,
          completionTokens: row['completion_tokens'] as int,
          replyCount: row['reply_count'] as int,
        ),
      );
    }
    return result;
  }

  /// Identity of one committed chat read view, including settings and body
  /// checkpoints which do not advance tree_revision. Cache only store data.
  Object displayVersion(String chatId) {
    _ensureOpen();
    // A committed token must not hide writes made earlier in this transaction.
    // Temporary identities also prevent rollback views entering later caches.
    return _transactionDepth == 0 ? _displayVersions.putIfAbsent(chatId, Object.new) : Object();
  }

  /// Only fields used by display and its macro/state context. In particular,
  /// neither the full inspection nor the original imported message is decoded.
  StoredNode displayNode(String chatId, String nodeId) {
    _ensureOpen();
    final rows = _db.select(
      'SELECT $_displayNodeColumns, $_siblingColumns FROM nodes n '
      'WHERE n.chat_id = ? AND n.id = ? AND n.deleted_by IS NULL',
      [chatId, nodeId],
    );
    if (rows.isEmpty) throw StateError('Node does not belong to chat: $nodeId');
    return _displayNode(rows.single);
  }

  /// Detached effective state for script variable/metadata readers. An object
  /// portable override, including an empty one, replaces the physical state.
  /// Does not construct a message, decode its source metadata or add a hash.
  Map<String, Object?> scriptNodeState(String chatId, String nodeId) {
    final row = _nodeRow(
      chatId,
      nodeId,
      columns: '''CASE WHEN json_type(n.display_context, '\$.dshgo.tavernState') = 'object'
        THEN json_extract(n.display_context, '\$.dshgo.tavernState') END AS state''',
    );
    final encoded = row['state'];
    return encoded == null ? nodeState(chatId, nodeId) : _map(encoded);
  }

  /// Walk only the positions from the current leaf back to the target depth.
  /// Hidden and actual system messages do not contribute display depth.
  ({bool onCurrentPath, int? depth}) displayPosition(String chatId, StoredNode target, String? leafId) {
    final usable =
        !target.message.hidden && target.message.role != TavernRole.system && target.original['is_system'] != true;
    if (leafId == null) return (onCurrentPath: false, depth: usable ? 0 : null);
    if (leafId == target.message.nodeId) return (onCurrentPath: true, depth: usable ? 0 : null);
    final row = _db
        .select(
          '''WITH RECURSIVE positions(id, parent_id, visible) AS (
      SELECT n.id, n.parent_id, $_displayVisible FROM nodes n
        WHERE n.chat_id = ? AND n.id = ? AND n.deleted_by IS NULL AND n.depth >= ?
      UNION
      SELECT n.id, n.parent_id, $_displayVisible FROM positions p CROSS JOIN nodes n ON n.id = p.parent_id
        WHERE n.chat_id = ? AND n.deleted_by IS NULL AND n.depth >= ?
    ) SELECT coalesce(max(id = ?), 0) AS found,
        coalesce(sum(CASE WHEN id != ? THEN visible ELSE 0 END), 0) AS following FROM positions''',
          [chatId, leafId, target.depth, chatId, target.depth, target.message.nodeId, target.message.nodeId],
        )
        .single;
    final found = row['found'] == 1;
    return (
      onCurrentPath: found,
      depth: usable
          ? found
                ? row['following'] as int
                : 0
          : null,
    );
  }

  /// Stop after two visible users and one visible non-user. This is enough
  /// for last/user/character/idle macros; only those nodes and the leaf leave
  /// SQLite. Counts saturate so stable UNION rows still terminate bad cycles.
  StoredDisplayHistory displayHistory(String chatId, String? leafId) {
    if (leafId == null) return const StoredDisplayHistory(length: 0);
    final rows = _db.select(
      '''WITH RECURSIVE history(id, parent_id, users, characters, take) AS (
      SELECT n.id, n.parent_id, ($_displayVisible AND n.role = 'user'),
        ($_displayVisible AND n.role != 'user'), 1 FROM nodes n
        WHERE n.chat_id = ? AND n.id = ? AND n.deleted_by IS NULL
      UNION
      SELECT n.id, n.parent_id,
        min(2, h.users + ($_displayVisible AND n.role = 'user')),
        min(1, h.characters + ($_displayVisible AND n.role != 'user')),
        ($_displayVisible AND ((n.role = 'user' AND h.users < 2) OR (n.role != 'user' AND h.characters < 1)))
      FROM history h CROSS JOIN nodes n ON n.id = h.parent_id
      WHERE n.chat_id = ? AND n.deleted_by IS NULL AND (h.users < 2 OR h.characters < 1)
    ) SELECT $_displayNodeColumns, $_siblingColumns FROM history h JOIN nodes n ON n.id = h.id
      WHERE h.take = 1 ORDER BY n.depth DESC''',
      [chatId, leafId, chatId],
    );
    if (rows.isEmpty) throw StateError('Node does not belong to chat: $leafId');
    final nodes = [for (final row in rows) _displayNode(row)];
    final visible = nodes
        .where(
          (node) =>
              !node.message.hidden && node.message.role != TavernRole.system && node.original['is_system'] != true,
        )
        .toList();
    final users = visible.where((node) => node.message.role == TavernRole.user);
    return StoredDisplayHistory(
      length: nodes.first.depth,
      last: nodes.first,
      user: users.firstOrNull,
      character: visible.where((node) => node.message.role != TavernRole.user).firstOrNull,
      previousUser: visible.firstOrNull?.message.role == TavernRole.user
          ? users.skip(1).firstOrNull
          : users.firstOrNull,
    );
  }

  /// Reads the entire ancestor path of an explicit leaf, including inactive
  /// branches and stored extra/original fields. There is no 60-message default.
  /// A non-null leaf uses two SELECTs: the chat check and the recursive query.
  List<StoredNode> historyTo(String chatId, String? leafId) {
    chatCharacterId(chatId);
    return [for (final row in _ancestorRows(chatId, leafId)) _storedNode(row)];
  }

  /// Read-only bridge message projection. It preserves every script-visible
  /// extra/state/swipe field, without inspection or duplicate imported bodies.
  /// Write plans and exporters must still read full [node]/[children] rows.
  List<StoredNode> scriptHistoryTo(String chatId, String? leafId) {
    chatCharacterId(chatId);
    return [
      for (final row in _ancestorRows(chatId, leafId, columns: '$_scriptNodeColumns, $_siblingColumns'))
        _scriptNode(row),
    ];
  }

  /// Visible swipe family with the same read projection as [scriptHistoryTo].
  List<StoredNode> scriptChildren(String chatId, String? parentId) {
    chatCharacterId(chatId);
    if (parentId != null &&
        _db.select('SELECT 1 FROM nodes WHERE chat_id = ? AND id = ? AND deleted_by IS NULL', [
          chatId,
          parentId,
        ]).isEmpty) {
      throw StateError('Node does not belong to chat: $parentId');
    }
    return [
      for (final row in _db.select(
        'SELECT $_scriptNodeColumns, $_siblingColumns FROM nodes n '
        'WHERE n.chat_id = ? AND n.parent_id IS ? AND n.deleted_by IS NULL ORDER BY n.seq',
        [chatId, parentId],
      ))
        _scriptNode(row),
    ];
  }

  List<StoredHistoryLink> historyLinksTo(String chatId, String? leafId) {
    chatCharacterId(chatId);
    return [
      for (final row in _ancestorRows(
        chatId,
        leafId,
        columns: '''
      n.id, n.parent_id, n.selected_child_id, n.role, n.hidden,
      n.seq, n.source_epoch, n.content_version,
      char(1) || n.speaker_character_id AS speaker_character_id,
      char(1) || n.speaker AS speaker, json_type(n.original, '\$.is_system') = 'true' AS is_system''',
      ))
        StoredHistoryLink(
          nodeId: row['id'] as String,
          selectedChildId: row['selected_child_id'] as String?,
          seq: row['seq'] as int,
          sourceEpoch: row['source_epoch'] as int,
          contentVersion: row['content_version'] as int,
          role: TavernRole.values.byName(row['role'] as String),
          speaker: _unguardText(row['speaker'])!,
          speakerCharacterId: _unguardText(row['speaker_character_id']),
          hidden: row['hidden'] == 1,
          isSystem: row['role'] == 'system' || row['is_system'] == 1,
        ),
    ];
  }

  /// A bounded prompt-only page. Old inspection/usage and unknown import
  /// fields are not materialized merely to assemble another request.
  List<StoredNode> promptHistoryTo(
    String chatId,
    String? leafId, {
    required int limit,
    bool includeSource = false,
    bool includeRuntime = false,
  }) {
    _ensureOpen();
    final extra = includeRuntime
        ? "json_object('dshgo', json_object('chatJsonl', json_extract(n.extra, '\$.dshgo.chatJsonl'), "
              "'group', json_extract(n.extra, '\$.dshgo.group')))"
        : includeSource
        ? "json_object('dshgo', json_object('chatJsonl', json_extract(n.extra, '\$.dshgo.chatJsonl')))"
        : "'{}'";
    return [
      for (final row in _ancestorRows(
        chatId,
        leafId,
        limit: limit,
        columns:
            '${includeRuntime ? _runtimePromptNodeColumns : _promptNodeColumns}, $extra AS extra, $_siblingColumns',
      ))
        _storedNode(row),
    ];
  }

  /// Reads only root-to-leaf identities, validating the same visible ancestor
  /// structure as [historyTo]. It does not decode message/state documents: bad
  /// unrelated extra/original JSON cannot invalidate a membership-only read.
  List<String> ancestorIds(String chatId, String? leafId) {
    chatCharacterId(chatId);
    return [for (final row in _ancestorRows(chatId, leafId, identitiesOnly: true)) row['id'] as String];
  }

  List<Row> _ancestorRows(String chatId, String? leafId, {int? limit, bool identitiesOnly = false, String? columns}) {
    if (limit == 0 || leafId == null) return [];
    // UNION only sees stable identifiers. Including an increasing distance
    // would defeat duplicate removal for a corrupt cycle. Both recursive
    // terms stay inside this chat; never trust a foreign parent pointer.
    // Drive each recursive step from its single parent id. Reordering this
    // join can scan every node in the chat once per ancestor.
    final projection = columns ?? (identitiesOnly ? 'a.id, a.parent_id' : '$_nodeColumns, $_siblingColumns');
    final source = identitiesOnly ? 'ancestors a' : 'ancestors a JOIN nodes n ON n.id = a.id';
    final rows = _db.select(
      '''WITH RECURSIVE ancestors(id, parent_id) AS (
           SELECT id, parent_id FROM nodes WHERE chat_id = ? AND id = ? AND deleted_by IS NULL
           UNION
           SELECT n.id, n.parent_id FROM ancestors a CROSS JOIN nodes n ON n.id = a.parent_id
             WHERE n.chat_id = ? AND n.deleted_by IS NULL
           LIMIT ?
         ) SELECT $projection FROM $source''',
      [chatId, leafId, chatId, limit ?? -1],
    );
    final byId = <String, Row>{for (final row in rows) row['id'] as String: row};
    final reversed = <Row>[];
    final visited = <String>{};
    String? next = leafId;
    while (next != null && (limit == null || reversed.length < limit)) {
      if (!visited.add(next)) throw _StoredAncestorDataError('Cycle in the ancestor path: $next');
      final row = byId[next];
      if (row == null) throw _StoredAncestorDataError('Node does not belong to chat or has a broken parent: $next');
      reversed.add(row);
      next = row['parent_id'] as String?;
    }
    return reversed.reversed.toList();
  }

  void selectSibling(String chatId, String nodeId, int index) {
    transaction(() {
      final row = _nodeRow(chatId, nodeId);
      final siblings = _db.select(
        'SELECT id FROM nodes WHERE chat_id = ? AND parent_id IS ? AND deleted_by IS NULL ORDER BY seq',
        [chatId, row['parent_id']],
      );
      RangeError.checkValidIndex(index, siblings, 'index');
      _activate(chatId, siblings[index]['id'] as String);
      _touch(chatId, tree: true);
    });
  }

  /// Selects a node and restores the path remembered beneath it. Clearing that
  /// remembered selection keeps descendants stored and stops the path here.
  void selectNode(String chatId, String nodeId, {bool restoreDescendants = true}) {
    transaction(() {
      _nodeRow(chatId, nodeId);
      if (!restoreDescendants) _db.execute('UPDATE nodes SET selected_child_id = NULL WHERE id = ?', [nodeId]);
      _activate(chatId, nodeId);
      _touch(chatId, tree: true);
    });
  }

  /// Restores an explicit empty active path without changing any remembered
  /// child choices or decoding message documents. An already empty path is a
  /// no-op, including its revision, timestamp and notifications.
  void clearSelection(String chatId) {
    transaction(() {
      final chat = _chatRow(chatId);
      if (chat['selected_root_id'] == null && chat['current_leaf_id'] == null) return;
      _db.execute('UPDATE chats SET selected_root_id = NULL, current_leaf_id = NULL WHERE id = ?', [chatId]);
      _touch(chatId, tree: true);
    });
  }

  /// Restores a complete selection snapshot, including inactive branches and
  /// explicit null stops. Every stored node must occur exactly once in the
  /// map. A null root keeps the tree but selects an empty path.
  ///
  /// Importers can assemble a tree with makeCurrent:false and publish all
  /// choices in O(nodes), without selectNode rewriting every ancestor for
  /// every imported row. Validation finishes before any selection is changed.
  void restoreSelection(
    String chatId, {
    required String? selectedRootId,
    required Map<String, String?> selectedChildren,
  }) {
    transaction(() {
      _chatRow(chatId);
      final choices = Map<String, String?>.of(selectedChildren);
      final rows = _db.select(
        'SELECT id, parent_id, selected_child_id FROM nodes WHERE chat_id = ? AND deleted_by IS NULL',
        [chatId],
      );
      final parents = <String, String?>{for (final row in rows) row['id'] as String: row['parent_id'] as String?};
      if (choices.length != parents.length || parents.keys.any((id) => !choices.containsKey(id))) {
        throw ArgumentError('A selection snapshot must contain every node of this chat, and no other nodes.');
      }
      if (selectedRootId != null && (!parents.containsKey(selectedRootId) || parents[selectedRootId] != null)) {
        throw ArgumentError.value(selectedRootId, 'selectedRootId', 'Must be a root of this chat.');
      }
      for (final entry in choices.entries) {
        final child = entry.value;
        if (child != null && (!parents.containsKey(child) || parents[child] != entry.key)) {
          throw ArgumentError('Selected child $child is not a child of ${entry.key} in this chat.');
        }
      }
      var leaf = selectedRootId;
      while (leaf != null && choices[leaf] != null) {
        leaf = choices[leaf];
      }
      for (final row in rows) {
        final id = row['id'] as String;
        if (row['selected_child_id'] != choices[id]) {
          _db.execute('UPDATE nodes SET selected_child_id = ? WHERE id = ?', [choices[id], id]);
        }
      }
      _db.execute('UPDATE chats SET selected_root_id = ?, current_leaf_id = ? WHERE id = ?', [
        selectedRootId,
        leaf,
        chatId,
      ]);
      _touch(chatId, tree: true);
    });
  }

  /// Saves only the current body channels. The ordinary text stays unchanged
  /// until the terminal update, keeping external-content FTS OLD values valid.
  /// Usage, state, inspection, original JSON and chat timestamps are untouched.
  void writeStreamingBody(String chatId, String nodeId, {required String text, String? reasoning}) {
    _ensureOpen();
    if (_streamingWriters == 0) throw StateError('A body checkpoint requires an active streaming writer.');
    _withDurability(1, () {
      if (_db.select('SELECT 1 FROM nodes WHERE chat_id = ? AND id = ? AND deleted_by IS NULL', [
        chatId,
        nodeId,
      ]).isEmpty) {
        throw StateError('Node does not belong to chat: $nodeId');
      }
      _db.execute('UPDATE nodes SET stream_text = ?, stream_reasoning = ? WHERE id = ?', [text, reasoning, nodeId]);
      _changedChats.add(chatId);
    }, bodyOnly: true);
  }

  TavernMessage updateMessage(
    String chatId,
    String nodeId, {
    TavernRole? role,
    String? speaker,
    bool? hidden,
    String? text,
    String? reasoning,
    String? speakerCharacterId,
    TavernUsage? usage,
    bool clearSpeakerCharacterId = false,
    bool clearReasoning = false,
    bool clearUsage = false,
    Map<String, Object?>? extra,
    Map<String, Object?>? original,
  }) {
    return transaction(() {
      final row = _nodeRow(chatId, nodeId);
      final hasDraft = row['stream_text'] != null;
      final promote = hasDraft && (text != null || reasoning != null || clearReasoning);
      final fields = <String>[];
      final values = <Object?>[];
      void put(String name, Object? value) {
        fields.add('$name = ?');
        values.add(value);
      }

      if (role != null) {
        put('role', role.name);
      }
      if (speaker != null) {
        put('speaker', speaker);
      }
      if (hidden != null) {
        put('hidden', hidden ? 1 : 0);
      }
      // UPDATE OF text drives the FTS trigger. Metadata-only writes must not
      // name text, and must not promote an in-progress body as a side effect.
      if (text != null || promote) put('text', text ?? _unguardText(row['stream_text']));
      final effectiveRole = role?.name ?? row['role'] as String;
      if (effectiveRole != TavernRole.character.name) {
        if (row['speaker_character_id'] != null) put('speaker_character_id', null);
      } else if (speakerCharacterId != null || clearSpeakerCharacterId) {
        put('speaker_character_id', clearSpeakerCharacterId ? null : speakerCharacterId);
      }
      if (reasoning != null || clearReasoning || promote) {
        put(
          'reasoning',
          clearReasoning ? null : reasoning ?? _unguardText(promote ? row['stream_reasoning'] : row['reasoning']),
        );
      }
      if (usage != null || clearUsage || promote) put('usage', clearUsage ? null : _encodeUsage(usage));
      if (extra != null || promote) {
        final nextExtra = extra ?? _nodeExtra(row);
        final encoded = _encodeNodeExtra(nextExtra, chatId, nodeId);
        put('extra', encoded.raw);
        put('reported_usage', encoded.reportedUsage);
        put('display_context', encoded.displayContext);
      }
      if (original != null) put('original', jsonEncode(original));
      if (promote) {
        put('stream_text', null);
        put('stream_reasoning', null);
      }
      if (fields.isNotEmpty) {
        _db.execute('UPDATE nodes SET ${fields.join(', ')} WHERE id = ?', [...values, nodeId]);
        _touch(chatId, tree: true);
      }
      return message(chatId, nodeId);
    });
  }

  void edit(String chatId, String nodeId, String text) {
    updateMessage(chatId, nodeId, text: text);
  }

  void setHidden(String chatId, String nodeId, bool hidden) {
    transaction(() {
      _nodeRow(chatId, nodeId);
      _db.execute('UPDATE nodes SET hidden = ? WHERE id = ?', [hidden ? 1 : 0, nodeId]);
      _touch(chatId, tree: true);
    });
  }

  /// Removes one visible message, attaching all physical children to its
  /// parent. Pending-deletion children retain their markers and can still be
  /// undone. The current path loses just this node; an active stop moves to
  /// its parent (or an empty path), never an adjacent sibling.
  ///
  /// Every direct child's original physical state becomes a full checkpoint.
  /// The optional synchronous [capturePortableState] runs before any edges
  /// change and must only compute a state from the old child/source metadata.
  /// Its result replaces only raw extra.dshgo.tavernState; physical state,
  /// inspection, reported usage and other raw fields remain independent.
  /// A throwing callback rolls back this operation. The facade restores the
  /// chat's runtime state after this structural edit in the same transaction.
  void deleteMessage(
    String chatId,
    String nodeId, {
    Map<String, Object?> Function(StoredNode child, Map<String, Object?> physicalState)? capturePortableState,
  }) {
    transaction(() {
      final chat = _chatRow(chatId);
      final target = _nodeRow(chatId, nodeId);
      final parentId = target['parent_id'] as String?;
      final selectedChildId = target['selected_child_id'] as String?;
      final selectedId = parentId == null
          ? chat['selected_root_id'] as String?
          : _nodeRow(chatId, parentId)['selected_child_id'] as String?;
      final children = _db.select(
        'SELECT $_nodeColumns, $_siblingColumns FROM nodes n WHERE n.chat_id = ? AND n.parent_id = ? ORDER BY n.seq',
        [chatId, nodeId],
      );
      final snapshots = <String, ({String state, _NodeExtraProjection? extra})>{};
      for (final child in children) {
        final childId = child['id'] as String;
        final state = _nodeStateSnapshot(chatId, childId, includeDeleted: true).state;
        // Encode before handing the detached map to the callback. A portable
        // override must never become the base of a descendant's physical delta.
        final physical = jsonEncode(state);
        _NodeExtraProjection? encodedExtra;
        if (capturePortableState != null) {
          final portable = capturePortableState(_storedNode(child), state);
          // _storedNode projects pending inspection out of its returned copy.
          // Merge into the original row instead, preserving that raw evidence.
          final extra = _map(child['extra']);
          final own = extra['dshgo'];
          extra['dshgo'] = {if (own is Map<String, Object?>) ...own, 'tavernState': portable};
          encodedExtra = _encodeNodeExtra(extra, chatId, childId);
        }
        snapshots[childId] = (state: physical, extra: encodedExtra);
      }

      // Traverse original edges, including marked children, before detaching.
      _db.execute(
        '''WITH RECURSIVE descendants(id) AS (
        SELECT id FROM nodes WHERE chat_id = ? AND parent_id = ?
        UNION SELECT n.id FROM nodes n JOIN descendants d ON n.parent_id = d.id WHERE n.chat_id = ?
      ) UPDATE nodes SET depth = depth - 1 WHERE id IN (SELECT id FROM descendants)''',
        [chatId, nodeId, chatId],
      );
      _db.execute('UPDATE nodes SET parent_id = ? WHERE chat_id = ? AND parent_id = ?', [parentId, chatId, nodeId]);
      for (final entry in snapshots.entries) {
        _db.execute('UPDATE node_states SET delta_json = ?, full_json = ? WHERE node_id = ?', [
          '[]',
          entry.value.state,
          entry.key,
        ]);
        final encoded = entry.value.extra;
        if (encoded != null) {
          _db.execute(
            'UPDATE nodes SET extra = ?, reported_usage = ?, display_context = ? WHERE chat_id = ? AND id = ?',
            [encoded.raw, encoded.reportedUsage, encoded.displayContext, chatId, entry.key],
          );
        }
      }
      if (selectedId == nodeId) {
        if (parentId == null) {
          _db.execute('UPDATE chats SET selected_root_id = ? WHERE id = ?', [selectedChildId, chatId]);
        } else {
          _db.execute('UPDATE nodes SET selected_child_id = ? WHERE id = ?', [selectedChildId, parentId]);
        }
      }
      if (chat['current_leaf_id'] == nodeId) {
        _db.execute('UPDATE chats SET current_leaf_id = ? WHERE id = ?', [parentId, chatId]);
      }
      _db.execute('DELETE FROM nodes WHERE chat_id = ? AND id = ?', [chatId, nodeId]);
      // Older undo snapshots can name this now-deleted parent or root. They
      // may restore visibility later, but must not restore those old choices.
      _touch(chatId, tree: true);
    });
  }

  /// Hides a subtree until undo or the next open, preserving every stored row
  /// and its state. User deletion uses this; failed-turn rollback uses the
  /// immediate [deleteFrom] below. The facade owns its runtime-state cleanup.
  String softDeleteFrom(String chatId, String nodeId) => transaction(() {
    final chat = _chatRow(chatId);
    final target = _nodeRow(chatId, nodeId);
    final parentId = target['parent_id'] as String?;
    final leafId = chat['current_leaf_id'] as String?;
    final changesCurrent = leafId != null && _isAncestor(chatId, nodeId, leafId);
    final selectedId = parentId == null
        ? chat['selected_root_id'] as String?
        : _nodeRow(chatId, parentId)['selected_child_id'] as String?;
    final siblings = _db.select(
      'SELECT id FROM nodes WHERE chat_id = ? AND parent_id IS ? AND id != ? AND deleted_by IS NULL ORDER BY seq',
      [chatId, parentId, nodeId],
    );
    final oldIndex = target['sibling_index'] as int;
    final replacement = siblings.isEmpty ? null : siblings[min(oldIndex, siblings.length - 1)]['id'] as String;
    final token = _createId();
    _db.execute(
      '''INSERT INTO deleted_subtrees
      (id, chat_id, root_node_id, parent_id, selected_child_id, selected_root_id, current_leaf_id, revision_after)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        token,
        chatId,
        nodeId,
        parentId,
        selectedId,
        chat['selected_root_id'],
        chat['current_leaf_id'],
        (chat['tree_revision'] as int) + 1,
      ],
    );
    _db.execute(
      '''WITH RECURSIVE subtree(id) AS (
      SELECT id FROM nodes WHERE chat_id = ? AND id = ?
      UNION SELECT n.id FROM nodes n JOIN subtree s ON n.parent_id = s.id WHERE n.chat_id = ?
    ) UPDATE nodes SET deleted_by = ? WHERE id IN (SELECT id FROM subtree) AND deleted_by IS NULL''',
      [chatId, nodeId, chatId, token],
    );
    if (selectedId == nodeId) {
      if (parentId == null) {
        _db.execute('UPDATE chats SET selected_root_id = ? WHERE id = ?', [replacement, chatId]);
      } else {
        _db.execute('UPDATE nodes SET selected_child_id = ? WHERE id = ?', [replacement, parentId]);
      }
    }
    if (changesCurrent) {
      final next = replacement ?? parentId;
      if (next == null) {
        _db.execute('UPDATE chats SET current_leaf_id = NULL, selected_root_id = NULL WHERE id = ?', [chatId]);
      } else {
        _activate(chatId, next);
      }
    }
    _touch(chatId, tree: true);
    return token;
  });

  /// Restores this batch's visibility. Later tree changes keep their current
  /// selection; undo never overwrites newer branches or chat metadata.
  /// An independently deleted ancestor blocks undo without consuming its token.
  bool undoDeleteFrom(String chatId, String deletionId) => transaction(() {
    final chat = _chatRow(chatId);
    final batches = _db.select('SELECT * FROM deleted_subtrees WHERE chat_id = ? AND id = ?', [chatId, deletionId]);
    if (batches.isEmpty) return false;
    final batch = batches.single;
    final roots = _db.select('SELECT parent_id FROM nodes WHERE chat_id = ? AND id = ? AND deleted_by = ?', [
      chatId,
      batch['root_node_id'],
      deletionId,
    ]);
    if (roots.isEmpty) return false;
    final blocked = _db.select(
      '''WITH RECURSIVE ancestors(id, parent_id, deleted_by) AS (
      SELECT id, parent_id, deleted_by FROM nodes WHERE chat_id = ? AND id = ?
      UNION SELECT n.id, n.parent_id, n.deleted_by FROM ancestors a CROSS JOIN nodes n ON n.id = a.parent_id
        WHERE n.chat_id = ?
    ) SELECT 1 FROM ancestors WHERE deleted_by IS NOT NULL LIMIT 1''',
      [chatId, roots.single['parent_id'], chatId],
    );
    if (blocked.isNotEmpty) return false;
    _db.execute('UPDATE nodes SET deleted_by = NULL WHERE chat_id = ? AND deleted_by = ?', [chatId, deletionId]);
    // Checkpoints intentionally write only body columns, not chat revisions.
    // A direct store caller may therefore have new pending text without a
    // revision change; it must keep that active path as well.
    final hasPending = _db.select(
      'SELECT 1 FROM nodes WHERE chat_id = ? AND deleted_by IS NULL AND stream_text IS NOT NULL LIMIT 1',
      [chatId],
    ).isNotEmpty;
    if (chat['tree_revision'] == batch['revision_after'] && !hasPending) {
      final parent = batch['parent_id'] as String?;
      if (parent != null) {
        _nodeRow(chatId, parent);
        _db.execute('UPDATE nodes SET selected_child_id = ? WHERE id = ?', [batch['selected_child_id'], parent]);
      }
      _db.execute('UPDATE chats SET selected_root_id = ?, current_leaf_id = ? WHERE id = ?', [
        batch['selected_root_id'],
        batch['current_leaf_id'],
        chatId,
      ]);
    }
    _db.execute('DELETE FROM deleted_subtrees WHERE id = ?', [deletionId]);
    _touch(chatId, tree: true);
    return true;
  });

  /// Removes every descendant in one SQL statement, avoiding the SQLite
  /// cascade-trigger depth limit on long conversations. If the selected child
  /// is deleted, choose its next surviving sibling (or the previous last one).
  /// Deleting a different branch does not move the current leaf.
  void deleteFrom(String chatId, String nodeId) {
    transaction(() {
      final chat = _chatRow(chatId);
      final target = _nodeRow(chatId, nodeId, includeDeleted: true);
      final parentId = target['parent_id'] as String?;
      final leafId = chat['current_leaf_id'] as String?;
      final changesCurrent = leafId != null && _isAncestor(chatId, nodeId, leafId);
      final selectedId = parentId == null
          ? chat['selected_root_id'] as String?
          : _nodeRow(chatId, parentId, includeDeleted: true)['selected_child_id'] as String?;
      final siblings = _db.select(
        'SELECT id FROM nodes WHERE chat_id = ? AND parent_id IS ? AND id != ? AND deleted_by IS NULL ORDER BY seq',
        [chatId, parentId, nodeId],
      );
      final oldIndex = target['sibling_index'] as int;
      final replacement = siblings.isEmpty ? null : siblings[min(oldIndex, siblings.length - 1)]['id'] as String;
      _db.execute(
        '''WITH RECURSIVE subtree(id) AS (
             SELECT id FROM nodes WHERE chat_id = ? AND id = ?
             UNION ALL SELECT n.id FROM nodes n JOIN subtree s ON n.parent_id = s.id
           ) DELETE FROM nodes WHERE id IN (SELECT id FROM subtree)''',
        [chatId, nodeId],
      );
      if (selectedId == nodeId) {
        if (parentId == null) {
          _db.execute('UPDATE chats SET selected_root_id = ? WHERE id = ?', [replacement, chatId]);
        } else {
          _db.execute('UPDATE nodes SET selected_child_id = ? WHERE id = ?', [replacement, parentId]);
        }
      }
      if (changesCurrent) {
        final newSelection = replacement ?? parentId;
        if (newSelection == null) {
          _db.execute('UPDATE chats SET current_leaf_id = NULL, selected_root_id = NULL WHERE id = ?', [chatId]);
        } else {
          _activate(chatId, newSelection);
        }
      }
      _db.execute(
        '''DELETE FROM deleted_subtrees WHERE chat_id = ? AND NOT EXISTS
        (SELECT 1 FROM nodes n WHERE n.chat_id = deleted_subtrees.chat_id AND n.id = deleted_subtrees.root_node_id)''',
        [chatId],
      );
      _touch(chatId, tree: true);
    });
  }

  void deleteChat(String chatId) {
    transaction(() {
      _chatRow(chatId);
      _db.execute('DELETE FROM chats WHERE id = ?', [chatId]);
      _changedChats.add(chatId);
    });
  }

  void deleteCharacterChats(String characterId) {
    transaction(() {
      final rows = _db.select(
        '''SELECT id FROM chats WHERE character_id = ?
        AND NOT EXISTS(SELECT 1 FROM group_chats g WHERE g.chat_id = chats.id)''',
        [characterId],
      );
      _db.execute(
        '''DELETE FROM chats WHERE character_id = ?
        AND NOT EXISTS(SELECT 1 FROM group_chats g WHERE g.chat_id = chats.id)''',
        [characterId],
      );
      _changedChats.addAll(rows.map((row) => row['id'] as String));
    });
  }

  /// Rebuilds from the nearest checkpoint, at most 19 intervening deltas.
  /// The initial empty state has [] deltas and {} checkpoints. Imported states
  /// can use top-level RFC 6902 add/replace/remove operations without losing
  /// nested arrays or objects; a changed top-level value is replaced whole.
  Map<String, Object?> nodeState(String chatId, String nodeId) => _nodeStateSnapshot(chatId, nodeId).state;

  /// Replaces this physical state only. Children become checkpoints of their
  /// old physical state before the parent changes, including retained deleted
  /// children. Portable overrides stay independent in raw extra; the caller
  /// writes the target override/audit in the same outer transaction.
  void writeNodeState(String chatId, String nodeId, Map<String, Object?> state) {
    final encoded = jsonEncode(state);
    transaction(() {
      _nodeRow(chatId, nodeId);
      final children = _db.select('SELECT id FROM nodes WHERE chat_id = ? AND parent_id = ?', [chatId, nodeId]);
      final snapshots = <String, String>{
        for (final child in children)
          child['id'] as String: jsonEncode(
            _nodeStateSnapshot(chatId, child['id'] as String, includeDeleted: true).state,
          ),
      };
      for (final entry in snapshots.entries) {
        _db.execute('UPDATE node_states SET delta_json = ?, full_json = ? WHERE node_id = ?', [
          '[]',
          entry.value,
          entry.key,
        ]);
      }
      _db.execute('UPDATE node_states SET delta_json = ?, full_json = ? WHERE node_id = ?', ['[]', encoded, nodeId]);
      _touch(chatId, tree: true);
    });
  }

  /// Reconnects an already prepared family plan without changing node ids or
  /// seq (which is the FTS rowid and sibling order). Unmentioned parent edges
  /// and attached branches remain. Every surviving child of a removed page
  /// must have an explicit surviving parent in the plan.
  ///
  /// Only roots whose parent changes need new full physical checkpoints.
  /// Their descendants continue from the identical physical base. A portable
  /// snapshot is computed separately, before any edge or selection changes.
  void rewriteTree(
    String chatId, {
    required Map<String, String?> parentByNode,
    required List<String> selectedPath,
    Map<String, String?> selectedChildren = const {},
    Set<String> deleteNodeIds = const {},
    Map<String, Object?> Function(StoredNode node, Map<String, Object?> physicalState)? capturePortableState,
  }) {
    final requestedParents = Map<String, String?>.of(parentByNode);
    final requestedChoices = Map<String, String?>.of(selectedChildren);
    final path = List<String>.of(selectedPath);
    final removed = Set<String>.of(deleteNodeIds);
    transaction(() {
      final chat = _chatRow(chatId);
      final rows = _db.select(
        'SELECT id, parent_id, selected_child_id, depth, deleted_by FROM nodes WHERE chat_id = ? ORDER BY seq',
        [chatId],
      );
      final byId = <String, Row>{for (final row in rows) row['id'] as String: row};
      for (final id in {...requestedParents.keys, ...removed}) {
        if (!byId.containsKey(id)) {
          throw StateError('Tree plan contains a foreign or missing node: $id');
        }
      }
      if (requestedParents.keys.any(removed.contains)) {
        throw ArgumentError('A removed page cannot also be reparented.');
      }
      final parents = <String, String?>{
        for (final row in rows)
          if (!removed.contains(row['id']))
            row['id'] as String: requestedParents.containsKey(row['id'])
                ? requestedParents[row['id']]
                : row['parent_id'] as String?,
      };
      for (final entry in parents.entries) {
        if (entry.value != null && !parents.containsKey(entry.value)) {
          throw ArgumentError('Tree plan leaves ${entry.key} under a missing parent.');
        }
      }

      // Compute depths iteratively, so a long real chat does not recurse on
      // the Dart stack. The identity graph also detects cycles before SQL.
      final depths = <String, int>{};
      for (final start in parents.keys) {
        if (depths.containsKey(start)) {
          continue;
        }
        final chain = <String>[];
        final visiting = <String>{};
        String? cursor = start;
        while (cursor != null && !depths.containsKey(cursor)) {
          if (!visiting.add(cursor)) {
            throw ArgumentError('Tree plan contains a parent cycle.');
          }
          chain.add(cursor);
          cursor = parents[cursor];
        }
        var depth = cursor == null ? 0 : depths[cursor]!;
        for (final id in chain.reversed) {
          depths[id] = ++depth;
        }
      }
      final seen = <String>{};
      String? previous;
      for (final id in path) {
        if (!seen.add(id) || !parents.containsKey(id) || byId[id]!['deleted_by'] != null || parents[id] != previous) {
          throw ArgumentError('Selected path must be a visible, complete path of the planned tree.');
        }
        previous = id;
      }

      final choices = <String, String?>{};
      for (final id in parents.keys) {
        final child = byId[id]!['selected_child_id'] as String?;
        choices[id] = child != null && parents.containsKey(child) && parents[child] == id ? child : null;
      }
      for (final entry in requestedChoices.entries) {
        if (!parents.containsKey(entry.key) ||
            entry.value != null &&
                (!parents.containsKey(entry.value) ||
                    parents[entry.value] != entry.key ||
                    byId[entry.value]!['deleted_by'] != null)) {
          throw ArgumentError('Remembered selection must identify a surviving direct child.');
        }
        choices[entry.key] = entry.value;
      }
      for (var index = 0; index < path.length; index++) {
        choices[path[index]] = index + 1 < path.length ? path[index + 1] : null;
      }
      final changedParents = <String, String?>{
        for (final entry in requestedParents.entries)
          if (byId[entry.key]!['parent_id'] != entry.value) entry.key: entry.value,
      };
      final snapshots = <String, ({String physical, _NodeExtraProjection? extra})>{};
      for (final id in changedParents.keys) {
        final row = _nodeRow(chatId, id, includeDeleted: true);
        final state = _nodeStateSnapshot(chatId, id, includeDeleted: true).state;
        final physical = jsonEncode(state);
        _NodeExtraProjection? encodedExtra;
        if (capturePortableState != null) {
          final portable = capturePortableState(_storedNode(row), state);
          final extra = _map(row['extra']);
          final own = extra['dshgo'];
          if (extra.containsKey('dshgo') && own is! Map<String, Object?>) {
            throw StateError('Cannot preserve a malformed internal dshgo container while moving a page.');
          }
          extra['dshgo'] = {if (own is Map<String, Object?>) ...own, 'tavernState': portable};
          encodedExtra = _encodeNodeExtra(extra, chatId, id);
        }
        snapshots[id] = (physical: physical, extra: encodedExtra);
      }

      final root = path.isEmpty ? null : path.first;
      final leaf = path.isEmpty ? null : path.last;
      final changed =
          changedParents.isNotEmpty ||
          removed.isNotEmpty ||
          chat['selected_root_id'] != root ||
          chat['current_leaf_id'] != leaf ||
          choices.entries.any((entry) => byId[entry.key]!['selected_child_id'] != entry.value);
      if (!changed) {
        return;
      }

      for (final entry in changedParents.entries) {
        _db.execute('UPDATE nodes SET parent_id = ? WHERE chat_id = ? AND id = ?', [entry.value, chatId, entry.key]);
      }
      for (final entry in snapshots.entries) {
        _db.execute('UPDATE node_states SET delta_json = ?, full_json = ? WHERE node_id = ?', [
          '[]',
          entry.value.physical,
          entry.key,
        ]);
        final encoded = entry.value.extra;
        if (encoded != null) {
          _db.execute(
            'UPDATE nodes SET extra = ?, reported_usage = ?, display_context = ? WHERE chat_id = ? AND id = ?',
            [encoded.raw, encoded.reportedUsage, encoded.displayContext, chatId, entry.key],
          );
        }
      }
      for (final id in removed) {
        _db.execute('DELETE FROM nodes WHERE chat_id = ? AND id = ?', [chatId, id]);
      }
      for (final id in parents.keys) {
        if (byId[id]!['depth'] != depths[id]) {
          _db.execute('UPDATE nodes SET depth = ? WHERE chat_id = ? AND id = ?', [depths[id], chatId, id]);
        }
        if (byId[id]!['selected_child_id'] != choices[id]) {
          _db.execute('UPDATE nodes SET selected_child_id = ? WHERE chat_id = ? AND id = ?', [choices[id], chatId, id]);
        }
      }
      _db.execute('UPDATE chats SET selected_root_id = ?, current_leaf_id = ? WHERE id = ?', [root, leaf, chatId]);
      _db.execute(
        '''DELETE FROM deleted_subtrees WHERE chat_id = ? AND NOT EXISTS
        (SELECT 1 FROM nodes n WHERE n.chat_id = deleted_subtrees.chat_id AND n.id = deleted_subtrees.root_node_id)''',
        [chatId],
      );
      _touch(chatId, tree: true);
    });
  }

  ({Map<String, Object?> state, int deltas}) _nodeStateSnapshot(
    String chatId,
    String nodeId, {
    bool includeDeleted = false,
  }) {
    _ensureOpen();
    if (_db.select(
      'SELECT 1 FROM nodes WHERE chat_id = ? AND id = ? '
      'AND (deleted_by IS NULL OR ? = 1)',
      [chatId, nodeId, includeDeleted ? 1 : 0],
    ).isEmpty) {
      throw StateError('Node does not belong to chat: $nodeId');
    }
    // Keep recursive rows stable so a corrupt cycle terminates in SQL before
    // the reconstruction below rejects it. A checkpoint still stops the walk.
    final rows = _db.select(
      '''WITH RECURSIVE states(id, parent_id, delta_json, full_json) AS (
           SELECT n.id, n.parent_id, s.delta_json, s.full_json
           FROM nodes n JOIN node_states s ON s.node_id = n.id WHERE n.chat_id = ? AND n.id = ?
           UNION
           SELECT n.id, n.parent_id, s.delta_json, s.full_json
           FROM states p JOIN nodes n ON n.id = p.parent_id JOIN node_states s ON s.node_id = n.id
           WHERE p.full_json IS NULL
         ) SELECT char(1) || id AS id, char(1) || parent_id AS parent_id,
             delta_json, full_json FROM states''',
      [chatId, nodeId],
    );
    // Keep the prefix in these internal keys: UTF-8 decoding must not merge a
    // leading-BOM identity with an otherwise identical unprefixed identity.
    final byId = <String, Row>{for (final row in rows) row['id'] as String: row};
    final reversed = <Row>[];
    final visited = <String>{};
    String? next = '\u0001$nodeId';
    while (next != null) {
      if (!visited.add(next)) {
        throw StateError('Cycle in the state ancestor path.');
      }
      final row = byId[next];
      if (row == null) {
        break;
      }
      reversed.add(row);
      if (row['full_json'] != null) {
        break;
      }
      next = row['parent_id'] as String?;
    }
    var state = <String, Object?>{};
    var deltas = 0;
    for (final row in reversed.reversed) {
      if (row['full_json'] != null) {
        state = _map(row['full_json']);
        deltas = 0;
      } else {
        deltas++;
        final delta = jsonDecode(row['delta_json'] as String) as List<Object?>;
        for (final value in delta) {
          final operation = value as Map<String, Object?>;
          final path = operation['path'] as String;
          final key = path.substring(1).replaceAll('~1', '/').replaceAll('~0', '~');
          switch (operation['op']) {
            case 'remove':
              state.remove(key);
            case 'add' || 'replace':
              state[key] = operation['value'];
            default:
              throw StateError('Unsupported stored state delta operation: ${operation['op']}');
          }
        }
      }
    }
    return (state: state, deltas: deltas);
  }

  /// Searches indexed bodies. Pending streaming bodies join only after final
  /// promotion, so an old indexed word cannot return unrelated new draft text.
  List<TavernMessage> search(String query, {String? chatId, int limit = 50}) {
    _ensureOpen();
    if (limit < 0) throw ArgumentError.value(limit, 'limit', 'Must be non-negative.');
    if (query.trim().isEmpty || limit == 0) return [];
    final rows = _db.select(
      '''SELECT $_nodeColumns, $_siblingColumns FROM nodes_fts JOIN nodes n ON n.seq = nodes_fts.rowid
         WHERE nodes_fts MATCH ? AND n.stream_text IS NULL AND n.deleted_by IS NULL AND (? IS NULL OR n.chat_id = ?) ORDER BY rank LIMIT ?''',
      [query, chatId, chatId, limit],
    );
    return [for (final row in rows) _message(row)];
  }

  /// Literal substring search over visible, finalized messages of one chat.
  /// SQLite's ASCII case folding applies; FTS syntax stays in [search].
  List<TavernMessage> searchChat(String chatId, String query, {int limit = 50}) {
    _chatRow(chatId);
    if (limit < 0) throw ArgumentError.value(limit, 'limit', 'Must be non-negative.');
    if (query.trim().isEmpty || limit == 0) return [];
    final rows = _db.select(
      '''SELECT $_nodeColumns, $_siblingColumns FROM (
      SELECT * FROM nodes n
      WHERE n.chat_id = ? AND n.deleted_by IS NULL AND n.stream_text IS NULL
        AND (instr(lower(n.text), lower(?)) > 0 OR instr(lower(n.speaker), lower(?)) > 0)
      ORDER BY n.seq DESC LIMIT ?
    ) AS n ORDER BY n.seq DESC''',
      [chatId, query, query, limit],
    );
    return [for (final row in rows) _message(row)];
  }

  /// Copies this live connection with SQLite's backup API. The caller keeps
  /// the source open and owns a new staging path; existing paths are refused.
  Future<int> backupToFile(File destination) async {
    _outsideTransaction();
    if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
      throw FileSystemException('Backup destination already exists.', destination.path);
    }
    _outsideTransaction();
    final target = sqlite3.open(destination.path);
    try {
      // The async generator finishes/frees its native backup before its stream
      // completes or throws. Never close target through a timeout race.
      // sqlite3 3.9.1 yields 250ms between steps; its default five-page batch
      // would stretch a large, otherwise idle backup across many tiny waits.
      await _db.backup(target, nPage: 1024).drain<void>();
      target.execute('PRAGMA journal_mode = DELETE');
      return target.select('PRAGMA user_version').single['user_version'] as int;
    } finally {
      target.close();
    }
  }

  /// Validates and upgrades only the restore module's unpublished staging DB.
  /// The original handle is read-only and closed before migrations start.
  static Future<void> validateBackup(File file, {required int sourceSchemaVersion}) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
      throw FileSystemException('Backup database is missing or is not a regular file.', file.path);
    }
    final original = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      final version = original.select('PRAGMA user_version').single['user_version'] as int;
      if (version != sourceSchemaVersion || version < 1 || version > schemaVersion) {
        throw const FormatException('Backup SQLite version does not match the supported manifest version.');
      }
      _checkBackupIntegrity(original);
    } finally {
      original.close();
    }
    final staged = ChatStore.open(file.path);
    try {
      _checkBackupIntegrity(staged._db);
    } finally {
      await staged.close();
    }
  }

  static void _checkBackupIntegrity(Database database) {
    final integrity = database.select('PRAGMA integrity_check');
    if (integrity.length != 1 || integrity.single.values.single != 'ok') {
      throw const FormatException('Backup SQLite integrity check failed.');
    }
    if (database.select('PRAGMA foreign_key_check').isNotEmpty) {
      throw const FormatException('Backup SQLite foreign-key check failed.');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    if (_transactionDepth != 0) throw StateError('Cannot close a chat store inside a transaction.');
    _streamingWriters = 0;
    _setSynchronous(2);
    _closed = true;
    _db.close();
    await _changes.close();
    await _chatCommits.close();
    await _presetChanges.close();
  }

  void _activate(String chatId, String nodeId) {
    final ancestors = _ancestorRows(chatId, nodeId);
    // Validate only the path being selected. Stable UNION rows terminate even
    // for corrupt cycles; chat/visibility/parent checks reject stale remembered
    // edges instead of following them into an unrelated branch or chat.
    final descendants = _db.select(
      '''WITH RECURSIVE descendants(id, parent_id, selected_child_id) AS (
           SELECT id, parent_id, selected_child_id FROM nodes
             WHERE chat_id = ? AND id = ? AND deleted_by IS NULL
           UNION
           SELECT n.id, n.parent_id, n.selected_child_id
           FROM descendants d CROSS JOIN nodes n ON n.id = d.selected_child_id
             WHERE n.chat_id = ? AND n.parent_id = d.id AND n.deleted_by IS NULL
         ) SELECT * FROM descendants''',
      [chatId, nodeId, chatId],
    );
    final byId = <String, Row>{for (final row in descendants) row['id'] as String: row};
    final visited = <String>{};
    var leaf = nodeId;
    while (true) {
      if (!visited.add(leaf)) {
        throw StateError('Cycle in the selected descendant path: $leaf');
      }
      final row = byId[leaf];
      if (row == null) {
        throw StateError('Selected child is not a visible child in this chat: $leaf');
      }
      final next = row['selected_child_id'] as String?;
      if (next == null) {
        break;
      }
      leaf = next;
    }
    for (var index = 0; index + 1 < ancestors.length; index++) {
      _db.execute('UPDATE nodes SET selected_child_id = ? WHERE id = ?', [
        ancestors[index + 1]['id'],
        ancestors[index]['id'],
      ]);
    }
    _db.execute('UPDATE chats SET selected_root_id = ?, current_leaf_id = ? WHERE id = ?', [
      ancestors.first['id'],
      leaf,
      chatId,
    ]);
  }

  bool _isAncestor(String chatId, String ancestorId, String nodeId) => _db
      .select(
        '''WITH RECURSIVE ancestors(id, parent_id) AS (
         SELECT id, parent_id FROM nodes WHERE chat_id = ? AND id = ? AND deleted_by IS NULL
         UNION SELECT n.id, n.parent_id FROM ancestors a CROSS JOIN nodes n ON n.id = a.parent_id WHERE n.chat_id = ? AND n.deleted_by IS NULL
       ) SELECT 1 FROM ancestors WHERE id = ? LIMIT 1''',
        [chatId, nodeId, chatId, ancestorId],
      )
      .isNotEmpty;

  Row _chatRow(String chatId, {String columns = _chatColumns}) {
    _ensureOpen();
    final rows = _db.select('SELECT $columns FROM chats c WHERE c.id = ?', [chatId]);
    if (rows.isEmpty) throw StateError('Chat not found: $chatId');
    return rows.first;
  }

  Row _nodeRow(
    String chatId,
    String nodeId, {
    bool includeDeleted = false,
    String columns = '$_nodeColumns, $_siblingColumns',
  }) {
    _ensureOpen();
    final rows = _db.select(
      'SELECT $columns FROM nodes n WHERE n.chat_id = ? AND n.id = ? AND (n.deleted_by IS NULL OR ? = 1)',
      [chatId, nodeId, includeDeleted ? 1 : 0],
    );
    if (rows.isEmpty) throw StateError('Node does not belong to chat: $nodeId');
    return rows.first;
  }

  void _touch(String chatId, {bool tree = false}) =>
      _touchAt(chatId, _clock().millisecondsSinceEpoch, treeChanges: tree ? 1 : 0);

  void _touchAt(String chatId, int milliseconds, {int treeChanges = 0}) {
    _db.execute('UPDATE chats SET updated_at = ?, tree_revision = tree_revision + ? WHERE id = ?', [
      milliseconds,
      treeChanges,
      chatId,
    ]);
    _changedChats.add(chatId);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('The chat store is closed.');
  }

  static StoredNode _storedNode(Row row) => StoredNode(
    message: _message(row),
    depth: row['depth'] as int,
    selectedChildId: row['selected_child_id'] as String?,
    extra: _nodeExtra(row),
    original: _map(row['original']),
  );

  static StoredNode _displayNode(Row row) => StoredNode(
    message: _message(row),
    depth: row['depth'] as int,
    selectedChildId: row['selected_child_id'] as String?,
    extra: {
      'dshgo': {
        if (row['display_state'] != null) 'tavernState': _map(row['display_state']),
        if (row['display_source'] != null) 'chatJsonl': _map(row['display_source']),
      },
    },
    original: {'is_system': row['display_system'] == 1},
  );

  static StoredNode _scriptNode(Row row) => StoredNode(
    message: _message(row),
    depth: row['depth'] as int,
    selectedChildId: row['selected_child_id'] as String?,
    extra: {
      ..._map(row['script_extra']),
      if (row['script_state'] != null) 'dshgo': {'tavernState': _map(row['script_state'])},
    },
    original: _map(row['original']),
  );

  static Map<String, Object?> _nodeExtra(Row row) {
    final extra = _map(row['extra']);
    if (row['stream_text'] != null) {
      final own = extra['dshgo'];
      if (own is Map<String, Object?>) own.remove('inspection');
    }
    return extra;
  }

  static TavernMessage _message(Row row) => TavernMessage(
    nodeId: row['id'] as String,
    parentId: row['parent_id'] as String?,
    role: TavernRole.values.byName(row['role'] as String),
    speaker: _unguardText(row['speaker'])!,
    speakerCharacterId: _unguardText(row['speaker_character_id']),
    text: _unguardText(row['stream_text'] ?? row['text'])!,
    reasoning: _unguardText(row['stream_text'] != null ? row['stream_reasoning'] : row['reasoning']),
    at: _date(row['at']),
    hidden: row['hidden'] == 1,
    siblingIndex: row['sibling_index'] as int,
    siblingCount: row['sibling_count'] as int,
    usage: row['stream_text'] == null ? _decodeUsage(row['usage']) : null,
    reportedUsage: row['stream_text'] == null ? _decodeUsage(row['reported_usage']) : null,
  );

  static DateTime _date(Object? value) => DateTime.fromMillisecondsSinceEpoch(value as int, isUtc: true);
  static Map<String, Object?> _map(Object? value) => jsonDecode(value as String) as Map<String, Object?>;

  // sqlite3's UTF-8 decoder removes a leading BOM. User TEXT projections add
  // char(1) before decoding; remove only that read-time guard, preserving null,
  // an original char(1), and every original BOM. Never persist the guarded value.
  static String? _unguardText(Object? value) => (value as String?)?.substring(1);

  static String? _encodeUsage(TavernUsage? usage) => usage == null
      ? null
      : jsonEncode({
          'promptTokens': usage.promptTokens,
          'cacheHitTokens': usage.cacheHitTokens,
          'completionTokens': usage.completionTokens,
          'model': usage.model,
        });

  // Every writer of extra uses the same already-owned map for these read
  // projections. Streaming recovery only removes inspection, leaving both
  // state/source and script-visible extra unchanged while clearing reported_usage.
  static _NodeExtraProjection _encodeNodeExtra(Map<String, Object?> extra, String chatId, String nodeId) {
    final own = extra['dshgo'];
    final state = own is Map<String, Object?> ? own['tavernState'] : null;
    final source = own is Map<String, Object?> ? own['chatJsonl'] : null;
    return _NodeExtraProjection(
      jsonEncode(extra),
      _reportedUsage(extra, chatId, nodeId),
      jsonEncode({
        'dshgo': {
          'tavernState': state is Map<String, Object?> ? state : null,
          'chatJsonl': source is Map<String, Object?> ? source : null,
        },
        'scriptExtra': {
          for (final entry in extra.entries)
            if (entry.key != 'dshgo') entry.key: entry.value,
        },
      }),
    );
  }

  // Read only this owned, small value. A path read never reconstructs the
  // inspection's prompt/trace or turns absent/invalid reporting into zero.
  static String? _reportedUsage(Map<String, Object?> extra, String chatId, String nodeId) {
    final own = extra['dshgo'];
    if (own is! Map<String, Object?>) return null;
    final inspection = own['inspection'];
    if (inspection is! Map<String, Object?> ||
        inspection['version'] != 1 ||
        inspection['chatId'] != chatId ||
        inspection['nodeId'] != nodeId) {
      return null;
    }
    final usage = inspection['reportedUsage'];
    if (usage is! Map<String, Object?> ||
        usage['promptTokens'] is! int ||
        usage['cacheHitTokens'] is! int ||
        usage['completionTokens'] is! int ||
        (usage['model'] != null && usage['model'] is! String)) {
      return null;
    }
    final startedAt = inspection['startedAt'];
    final startedAtMs = startedAt is String ? DateTime.tryParse(startedAt)?.millisecondsSinceEpoch : null;
    return jsonEncode({
      'promptTokens': usage['promptTokens'],
      'cacheHitTokens': usage['cacheHitTokens'],
      'completionTokens': usage['completionTokens'],
      'model': usage['model'],
      'startedAtMs': ?startedAtMs,
    });
  }

  static TavernUsage? _decodeUsage(Object? value) {
    if (value == null) return null;
    final usage = _map(value);
    return TavernUsage(
      promptTokens: usage['promptTokens'] as int,
      cacheHitTokens: usage['cacheHitTokens'] as int,
      completionTokens: usage['completionTokens'] as int,
      model: usage['model'] as String?,
    );
  }

  static List<Map<String, Object?>> _stateDiff(Map<String, Object?> before, Map<String, Object?> after) {
    String pointer(String key) => '/${key.replaceAll('~', '~0').replaceAll('/', '~1')}';
    return [
      for (final key in before.keys)
        if (!after.containsKey(key)) {'op': 'remove', 'path': pointer(key)},
      for (final key in after.keys)
        if (!before.containsKey(key))
          {'op': 'add', 'path': pointer(key), 'value': after[key]}
        else if (jsonEncode(before[key]) != jsonEncode(after[key]))
          {'op': 'replace', 'path': pointer(key), 'value': after[key]},
    ];
  }

  static String _newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static const _insertNodeSql = '''INSERT INTO nodes
    (id, chat_id, parent_id, depth, role, speaker, text, reasoning, at, hidden, usage, reported_usage, display_context, extra, original, speaker_character_id)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''';

  // Explicit projections read each potentially long body only once. JSON
  // containers and host-generated identities do not need a decoding guard.
  static const _nodeColumns = '''
    n.seq, n.id, n.chat_id, n.parent_id, n.selected_child_id, n.depth, n.role,
    char(1) || n.speaker AS speaker, char(1) || n.text AS text,
    char(1) || n.reasoning AS reasoning, n.at, n.hidden, n.usage, n.extra, n.original,
    char(1) || n.stream_text AS stream_text, char(1) || n.stream_reasoning AS stream_reasoning,
    n.deleted_by, n.reported_usage, char(1) || n.speaker_character_id AS speaker_character_id''';

  static const _displayVisible =
      "(n.hidden = 0 AND n.role != 'system' AND "
      "coalesce(json_type(n.original, '\$.is_system') != 'true', 1))";
  static const _displayNodeColumns = '''
    n.id, n.parent_id, n.selected_child_id, n.depth, n.role,
    char(1) || n.speaker AS speaker, char(1) || n.text AS text,
    char(1) || n.reasoning AS reasoning, n.at, n.hidden,
    char(1) || n.stream_text AS stream_text, char(1) || n.stream_reasoning AS stream_reasoning,
    char(1) || n.speaker_character_id AS speaker_character_id, NULL AS usage, NULL AS reported_usage,
    json_type(n.original, '\$.is_system') = 'true' AS display_system,
    CASE WHEN json_type(n.display_context, '\$.dshgo.tavernState') = 'object'
      THEN json_extract(n.display_context, '\$.dshgo.tavernState') END AS display_state,
    CASE WHEN json_type(n.display_context, '\$.dshgo.chatJsonl') = 'object'
      THEN json_extract(n.display_context, '\$.dshgo.chatJsonl') END AS display_source''';

  static const _scriptNodeColumns = '''
    n.id, n.parent_id, n.selected_child_id, n.depth, n.role,
    char(1) || n.speaker AS speaker, char(1) || n.text AS text,
    NULL AS reasoning, n.at, n.hidden,
    char(1) || n.stream_text AS stream_text, NULL AS stream_reasoning,
    char(1) || n.speaker_character_id AS speaker_character_id, NULL AS usage, NULL AS reported_usage,
    CASE WHEN json_type(n.display_context, '\$.scriptExtra') = 'object'
      THEN json_extract(n.display_context, '\$.scriptExtra')
      ELSE json_remove(n.extra, '\$.dshgo') END AS script_extra,
    CASE WHEN json_type(n.display_context, '\$.dshgo.tavernState') = 'object'
      THEN json_extract(n.display_context, '\$.dshgo.tavernState') END AS script_state,
    json_remove(n.original, '\$.mes', '\$.swipes', '\$.extra') AS original''';

  static const _promptNodeColumns = '''
    n.seq, n.id, n.chat_id, n.parent_id, n.selected_child_id, n.depth, n.role,
    char(1) || n.speaker AS speaker, char(1) || n.text AS text,
    NULL AS reasoning, n.at, n.hidden, NULL AS usage,
    json_object('is_system', json(CASE WHEN json_type(n.original, '\$.is_system') = 'true' THEN 'true' ELSE 'false' END),
      'force_avatar', json_extract(n.original, '\$.force_avatar'),
      'tool_calls', json_extract(n.original, '\$.tool_calls'),
      'tool_call_id', json_extract(n.original, '\$.tool_call_id')) AS original,
    char(1) || n.stream_text AS stream_text, NULL AS stream_reasoning,
    n.deleted_by, NULL AS reported_usage, char(1) || n.speaker_character_id AS speaker_character_id''';

  static final _runtimePromptNodeColumns = _promptNodeColumns
      .replaceFirst('NULL AS reasoning', 'char(1) || n.reasoning AS reasoning')
      .replaceFirst('NULL AS stream_reasoning', 'char(1) || n.stream_reasoning AS stream_reasoning');

  static const _chatColumns = '''
    c.id, c.character_id, char(1) || c.title AS title, c.created_at, c.updated_at,
    c.persona_id, c.preset_id, c.selected_root_id, c.current_leaf_id,
    c.metadata, c.variables, c.settings, c.tree_revision''';

  static const _siblingColumns = '''
    (SELECT COUNT(*) FROM nodes s WHERE s.chat_id = n.chat_id AND s.parent_id IS n.parent_id AND s.deleted_by IS NULL AND s.seq < n.seq)
      AS sibling_index,
    (SELECT COUNT(*) FROM nodes s WHERE s.chat_id = n.chat_id AND s.parent_id IS n.parent_id AND s.deleted_by IS NULL) AS sibling_count''';

  static const _schemaV1 = '''
CREATE TABLE chats (
  id TEXT PRIMARY KEY NOT NULL,
  character_id TEXT NOT NULL,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  persona_id TEXT,
  preset_id TEXT,
  selected_root_id TEXT REFERENCES nodes(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  current_leaf_id TEXT REFERENCES nodes(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  metadata TEXT NOT NULL DEFAULT '{}',
  variables TEXT NOT NULL DEFAULT '{}',
  settings TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX chats_character_updated ON chats(character_id, updated_at DESC);
CREATE TABLE nodes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT UNIQUE NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  parent_id TEXT REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,
  selected_child_id TEXT REFERENCES nodes(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  depth INTEGER NOT NULL CHECK(depth >= 1),
  role TEXT NOT NULL CHECK(role IN ('user', 'character', 'narrator', 'system')),
  speaker TEXT NOT NULL,
  text TEXT NOT NULL,
  reasoning TEXT,
  at INTEGER NOT NULL,
  hidden INTEGER NOT NULL DEFAULT 0 CHECK(hidden IN (0, 1)),
  usage TEXT,
  extra TEXT NOT NULL DEFAULT '{}',
  original TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX nodes_chat_parent ON nodes(chat_id, parent_id, seq);
CREATE INDEX nodes_parent ON nodes(parent_id);
CREATE INDEX nodes_selected_child ON nodes(selected_child_id);
CREATE INDEX chats_selected_root ON chats(selected_root_id);
CREATE INDEX chats_current_leaf ON chats(current_leaf_id);
CREATE TABLE node_states (
  node_id TEXT PRIMARY KEY NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  delta_json TEXT NOT NULL DEFAULT '[]',
  full_json TEXT
);
CREATE TABLE summaries (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  from_node_id TEXT REFERENCES nodes(id) ON DELETE CASCADE,
  to_node_id TEXT REFERENCES nodes(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  manually_edited INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE memories (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  entry_json TEXT NOT NULL
);
CREATE TABLE agent_runs (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  node_id TEXT REFERENCES nodes(id) ON DELETE SET NULL,
  kind TEXT NOT NULL,
  at INTEGER NOT NULL,
  usage TEXT,
  result_json TEXT
);
CREATE VIRTUAL TABLE nodes_fts USING fts5(text, speaker, content = 'nodes', content_rowid = 'seq');
CREATE TRIGGER nodes_fts_insert AFTER INSERT ON nodes BEGIN
  INSERT INTO nodes_fts(rowid, text, speaker) VALUES (new.seq, new.text, new.speaker);
END;
CREATE TRIGGER nodes_fts_delete AFTER DELETE ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, text, speaker) VALUES ('delete', old.seq, old.text, old.speaker);
END;
CREATE TRIGGER nodes_fts_update AFTER UPDATE OF text, speaker ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, text, speaker) VALUES ('delete', old.seq, old.text, old.speaker);
  INSERT INTO nodes_fts(rowid, text, speaker) VALUES (new.seq, new.text, new.speaker);
END;
''';

  static const _schemaV9 = r'''
CREATE INDEX nodes_path_ancestry ON nodes(id, chat_id, parent_id, deleted_by);
CREATE INDEX nodes_reported_path ON nodes(chat_id, id, at, reported_usage)
  WHERE deleted_by IS NULL AND role = 'character' AND stream_text IS NULL AND reported_usage IS NOT NULL;
ALTER TABLE nodes ADD COLUMN display_context TEXT;
UPDATE nodes SET display_context = CASE WHEN json_valid(extra) THEN
  json_object('dshgo', json_object(
    'tavernState', CASE WHEN json_type(extra, '$.dshgo.tavernState') = 'object'
      THEN json_extract(extra, '$.dshgo.tavernState') END,
    'chatJsonl', CASE WHEN json_type(extra, '$.dshgo.chatJsonl') = 'object'
      THEN json_extract(extra, '$.dshgo.chatJsonl') END))
  ELSE extra END;
''';

  static const _schemaV7 = '''
ALTER TABLE nodes ADD COLUMN speaker_character_id TEXT;
CREATE TABLE group_chats (
  chat_id TEXT PRIMARY KEY NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  activation TEXT NOT NULL,
  max_speakers INTEGER NOT NULL CHECK(max_speakers > 0),
  allow_self_responses INTEGER NOT NULL CHECK(allow_self_responses IN (0, 1)),
  initial_state TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE group_members (
  chat_id TEXT NOT NULL REFERENCES group_chats(chat_id) ON DELETE CASCADE,
  character_id TEXT NOT NULL,
  position INTEGER NOT NULL,
  talkativeness REAL NOT NULL CHECK(talkativeness >= 0 AND talkativeness <= 1),
  muted INTEGER NOT NULL CHECK(muted IN (0, 1)),
  model_role TEXT NOT NULL,
  PRIMARY KEY(chat_id, character_id)
);
CREATE INDEX group_members_character ON group_members(character_id);
''';

  static const _schemaV6 = '''
CREATE INDEX agent_runs_chat_kind ON agent_runs(chat_id, kind);
''';

  static const _schemaV5 = r'''
ALTER TABLE chats ADD COLUMN tree_revision INTEGER NOT NULL DEFAULT 0;
CREATE TABLE deleted_subtrees (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  root_node_id TEXT NOT NULL,
  parent_id TEXT,
  selected_child_id TEXT,
  selected_root_id TEXT,
  current_leaf_id TEXT,
  revision_after INTEGER NOT NULL
);
CREATE INDEX deleted_subtrees_chat ON deleted_subtrees(chat_id);
ALTER TABLE nodes ADD COLUMN deleted_by TEXT REFERENCES deleted_subtrees(id) DEFERRABLE INITIALLY DEFERRED;
CREATE INDEX nodes_deleted_by ON nodes(deleted_by) WHERE deleted_by IS NOT NULL;
ALTER TABLE nodes ADD COLUMN reported_usage TEXT;
UPDATE nodes SET reported_usage = CASE WHEN json_valid(extra) THEN CASE WHEN
  json_type(extra, '$.dshgo.inspection') = 'object'
  AND json_type(extra, '$.dshgo.inspection.version') IN ('integer', 'real')
  AND json_extract(extra, '$.dshgo.inspection.version') = 1
  AND json_type(extra, '$.dshgo.inspection.chatId') = 'text'
  AND json_extract(extra, '$.dshgo.inspection.chatId') = chat_id
  AND json_type(extra, '$.dshgo.inspection.nodeId') = 'text'
  AND json_extract(extra, '$.dshgo.inspection.nodeId') = id
  AND json_type(extra, '$.dshgo.inspection.reportedUsage') = 'object'
  AND json_type(extra, '$.dshgo.inspection.reportedUsage.promptTokens') = 'integer'
  AND json_type(extra, '$.dshgo.inspection.reportedUsage.cacheHitTokens') = 'integer'
  AND json_type(extra, '$.dshgo.inspection.reportedUsage.completionTokens') = 'integer'
  AND (json_type(extra, '$.dshgo.inspection.reportedUsage.model') IS NULL
    OR json_type(extra, '$.dshgo.inspection.reportedUsage.model') IN ('null', 'text'))
  THEN json_object(
    'promptTokens', json_extract(extra, '$.dshgo.inspection.reportedUsage.promptTokens'),
    'cacheHitTokens', json_extract(extra, '$.dshgo.inspection.reportedUsage.cacheHitTokens'),
    'completionTokens', json_extract(extra, '$.dshgo.inspection.reportedUsage.completionTokens'),
    'model', json_extract(extra, '$.dshgo.inspection.reportedUsage.model'))
  END END;
''';

  static const _schemaV4 = '''
ALTER TABLE nodes ADD COLUMN stream_text TEXT;
ALTER TABLE nodes ADD COLUMN stream_reasoning TEXT;
CREATE INDEX nodes_stream_pending ON nodes(chat_id) WHERE stream_text IS NOT NULL;
''';

  static const _schemaV3 = '''
ALTER TABLE presets ADD COLUMN import_report_json TEXT;
''';

  static const _schemaV2 = '''
CREATE TABLE presets (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL,
  source_text TEXT NOT NULL,
  raw_json TEXT NOT NULL,
  envelope_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE preset_preferences (
  singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
  default_preset_id TEXT REFERENCES presets(id) ON DELETE SET NULL
);
INSERT INTO preset_preferences(singleton, default_preset_id) VALUES (1, NULL);
CREATE INDEX chats_preset ON chats(preset_id);
''';
}
