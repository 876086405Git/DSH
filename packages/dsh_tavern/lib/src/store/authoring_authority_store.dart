part of 'chat_store.dart';

final class StoredAuthoringResource {
  const StoredAuthoringResource({
    required this.revision,
    required this.snapshot,
    this.pendingOperationId,
    this.rawTextId,
  });
  final int revision;
  final Map<String, Object?> snapshot;
  final String? pendingOperationId;
  final int? rawTextId;
}

/// Synchronous primitives used by the authority on this same connection.
/// Mutations belong to its existing FULL transaction; no file I/O runs there.
extension AuthoringAuthorityStore on ChatStore {
  ({String? domainId, bool hasPending, Set<String> protectedArtifacts}) authoringRootStateData() {
    _ensureOpen();
    return inspectAuthoringDatabase(_db);
  }

  String get authoringDatabasePath {
    _ensureOpen();
    return _db.select('PRAGMA database_list').singleWhere((row) => row['name'] == 'main')['file'] as String;
  }

  String get authoringDomainId {
    _ensureOpen();
    return _db.select('SELECT domain_id FROM authoring_domain WHERE singleton = 1').single['domain_id'] as String;
  }

  String newAuthoringOperationId() => ChatStore._newId();

  void initializeAuthoringAuthority() => transaction(() {
    if (_db.select('SELECT domain_id FROM authoring_domain WHERE singleton = 1').isEmpty) {
      _db.execute('INSERT INTO authoring_domain (singleton, domain_id) VALUES (1, ?)', [ChatStore._newId()]);
    }
    _db.execute("UPDATE authoring_operations SET state = 'unconfirmed', updated_at = ? WHERE state = 'prepared'", [
      _clock().millisecondsSinceEpoch,
    ]);
  });

  void rotateAuthoringDomain() => transaction(() {
    _db.execute('UPDATE authoring_domain SET domain_id = ? WHERE singleton = 1', [ChatStore._newId()]);
  });

  StoredAuthoringResource? readAuthoringResource(String resourceId) {
    _ensureOpen();
    final rows = _db.select(
      'SELECT r.revision, r.present, r.raw_text_id, char(1) || COALESCE(p.raw_text, r.raw_text) AS raw_text, '
      'char(1) || r.identity_text AS identity_text, char(1) || r.pending_operation_id AS pending_operation_id '
      'FROM authoring_resources r LEFT JOIN authoring_payloads p ON p.payload_id = r.raw_text_id '
      'WHERE r.physical_resource_id = ?',
      [resourceId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return StoredAuthoringResource(
      revision: row['revision'] as int,
      snapshot: {
        'present': row['present'] == 1,
        'rawText': ChatStore._unguardText(row['raw_text']),
        'identityText': ChatStore._unguardText(row['identity_text']),
      },
      pendingOperationId: ChatStore._unguardText(row['pending_operation_id']),
      rawTextId: row['raw_text_id'] as int?,
    );
  }

  ({int revision, String? pendingOperationId})? readAuthoringResourceHead(String resourceId) {
    _ensureOpen();
    final rows = _db.select(
      'SELECT revision, char(1) || pending_operation_id AS pending_operation_id '
      'FROM authoring_resources WHERE physical_resource_id = ?',
      [resourceId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return (revision: row['revision'] as int, pendingOperationId: ChatStore._unguardText(row['pending_operation_id']));
  }

  void setAuthoringResourcePending(String resourceId, String? operationId) {
    _db.execute('UPDATE authoring_resources SET pending_operation_id = ? WHERE physical_resource_id = ?', [
      operationId,
      resourceId,
    ]);
  }

  void putAuthoringResource(
    String resourceId,
    int revision,
    Map<String, Object?> snapshot, {
    String? pendingOperationId,
    int? rawTextId,
  }) {
    final previous = _db.select('SELECT raw_text_id FROM authoring_resources WHERE physical_resource_id = ?', [
      resourceId,
    ]);
    final oldTextId = previous.isEmpty ? null : previous.single['raw_text_id'] as int?;
    final nextTextId = rawTextId ?? _insertAuthoringPayload(snapshot['rawText'] as String?);
    _db.execute(
      'INSERT INTO authoring_resources '
      '(physical_resource_id, revision, present, raw_text, identity_text, pending_operation_id, raw_text_id) '
      'VALUES (?, ?, ?, NULL, ?, ?, ?) '
      'ON CONFLICT(physical_resource_id) DO UPDATE SET revision = excluded.revision, present = excluded.present, '
      'raw_text = NULL, identity_text = excluded.identity_text, pending_operation_id = excluded.pending_operation_id, '
      'raw_text_id = excluded.raw_text_id',
      [
        resourceId,
        revision,
        snapshot['present'] == true ? 1 : 0,
        snapshot['identityText'],
        pendingOperationId,
        nextTextId,
      ],
    );
    if (oldTextId != null && oldTextId != nextTextId) _discardUnusedAuthoringPayload(oldTextId);
  }

  void adoptAuthoringResourceData(String resourceId, int revision, String domainId, String operationId) {
    final row = _db.select(
      'SELECT after_json, after_raw_text_id FROM authoring_operations WHERE domain_id = ? AND operation_id = ?',
      [domainId, operationId],
    ).single;
    putAuthoringResource(
      resourceId,
      revision,
      ChatStore._map(row['after_json']),
      rawTextId: row['after_raw_text_id'] as int?,
    );
  }

  int? _insertAuthoringPayload(String? text) {
    if (text == null) return null;
    _db.execute('INSERT INTO authoring_payloads (raw_text) VALUES (?)', [text]);
    return _db.lastInsertRowId;
  }

  void _discardUnusedAuthoringPayload(int id) {
    _db.execute(
      'DELETE FROM authoring_payloads WHERE payload_id = ? '
      'AND NOT EXISTS (SELECT 1 FROM authoring_resources WHERE raw_text_id = ?) '
      'AND NOT EXISTS (SELECT 1 FROM authoring_operations WHERE before_raw_text_id = ?) '
      'AND NOT EXISTS (SELECT 1 FROM authoring_operations WHERE after_raw_text_id = ?)',
      [id, id, id, id],
    );
  }

  TavernAuthoringReceipt? readAuthoringReceiptData(String domainId, String operationId) {
    _ensureOpen();
    final rows = _db.select(
      'SELECT domain_id, char(1) || operation_id AS guarded_operation_id, physical_resource_id, '
      'state, adopted_revision, issue_json FROM authoring_operations WHERE domain_id = ? AND operation_id = ?',
      [domainId, operationId],
    );
    return rows.isEmpty ? null : _authoringReceiptRow(rows.single);
  }

  TavernAuthoringOperation? readAuthoringOperationData(String domainId, String operationId) {
    _ensureOpen();
    final rows = _db.select(
      'SELECT *, char(1) || operation_id AS guarded_operation_id FROM authoring_operations '
      'WHERE domain_id = ? AND operation_id = ?',
      [domainId, operationId],
    );
    return rows.isEmpty ? null : _authoringOperationRow(rows.single);
  }

  List<TavernAuthoringRevisionSummary> listAuthoringRevisionsData(String resourceId) {
    _ensureOpen();
    return [
      for (final row in _db.select(
        'SELECT domain_id, char(1) || operation_id AS operation_id, '
        'adopted_revision, updated_at FROM authoring_operations WHERE physical_resource_id = ? '
        'AND adopted_revision IS NOT NULL ORDER BY created_at DESC, domain_id, adopted_revision DESC',
        [resourceId],
      ))
        TavernAuthoringRevisionSummary(
          domainId: row['domain_id'] as String,
          physicalResourceId: resourceId,
          revision: row['adopted_revision'] as int,
          operationId: ChatStore._unguardText(row['operation_id'])!,
          at: ChatStore._date(row['updated_at']),
        ),
    ];
  }

  TavernAuthoringOperation? readAuthoringRevisionData(String resourceId, TavernAuthorityRevision revision) {
    _ensureOpen();
    final rows = _db.select(
      'SELECT *, char(1) || operation_id AS guarded_operation_id FROM authoring_operations '
      'WHERE domain_id = ? AND physical_resource_id = ? AND adopted_revision = ?',
      [revision.domainId, resourceId, revision.revision],
    );
    return rows.isEmpty ? null : _authoringOperationRow(rows.single);
  }

  void insertAuthoringOperationData({
    required String domainId,
    required String operationId,
    required String resourceId,
    required Map<String, Object?> parameters,
    required int baseRevision,
    required Map<String, Object?> before,
    required Map<String, Object?> after,
    required List<String> artifacts,
    required TavernAuthoringOperationState state,
  }) {
    final now = _clock().millisecondsSinceEpoch;
    var beforeTextId =
        _db.select('SELECT raw_text_id FROM authoring_resources WHERE physical_resource_id = ?', [
              resourceId,
            ]).single['raw_text_id']
            as int?;
    // A legacy inline resource is converted only when it next participates in
    // a write. Opening a large old library does not rewrite its history.
    if (beforeTextId == null && before['rawText'] != null) {
      beforeTextId = _insertAuthoringPayload(before['rawText'] as String);
      _db.execute('UPDATE authoring_resources SET raw_text = NULL, raw_text_id = ? WHERE physical_resource_id = ?', [
        beforeTextId,
        resourceId,
      ]);
    }
    final afterTextId = before['rawText'] == after['rawText']
        ? beforeTextId
        : _insertAuthoringPayload(after['rawText'] as String?);
    final requestAfter = parameters['after'];
    final usesAfter =
        requestAfter is Map<String, Object?> &&
        requestAfter.length == after.length &&
        after.entries.every((entry) => requestAfter.containsKey(entry.key) && requestAfter[entry.key] == entry.value);
    final request = usesAfter ? (Map<String, Object?>.of(parameters)..remove('after')) : parameters;
    _db.execute(
      'INSERT INTO authoring_operations '
      '(domain_id, operation_id, physical_resource_id, request_json, base_revision, before_json, after_json, '
      'artifacts_json, state, created_at, updated_at, before_raw_text_id, after_raw_text_id, request_uses_after) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        domainId,
        operationId,
        resourceId,
        jsonEncode(request),
        baseRevision,
        jsonEncode({...before, 'rawText': null}),
        jsonEncode({...after, 'rawText': null}),
        jsonEncode(artifacts),
        state.name,
        now,
        now,
        beforeTextId,
        afterTextId,
        usesAfter ? 1 : 0,
      ],
    );
  }

  void finishAuthoringOperationData(
    String domainId,
    String operationId,
    TavernAuthoringOperationState state, {
    int? adoptedRevision,
    TavernAuthoringIssue? issue,
  }) {
    _db.execute(
      'UPDATE authoring_operations SET state = ?, adopted_revision = ?, issue_json = ?, updated_at = ? '
      'WHERE domain_id = ? AND operation_id = ?',
      [
        state.name,
        adoptedRevision,
        issue == null ? null : jsonEncode({'type': issue.type, 'message': issue.message}),
        _clock().millisecondsSinceEpoch,
        domainId,
        operationId,
      ],
    );
  }

  TavernAuthoringReceipt _authoringReceiptRow(Row row) {
    final state = TavernAuthoringOperationState.values.byName(row['state'] as String);
    final issue = row['issue_json'] == null ? null : ChatStore._map(row['issue_json']);
    return TavernAuthoringReceipt(
      domainId: row['domain_id'] as String,
      operationId: ChatStore._unguardText(row['guarded_operation_id'])!,
      physicalResourceId: row['physical_resource_id'] as String,
      state: state,
      adoptedRevision: row['adopted_revision'] as int?,
      historyPending: state == TavernAuthoringOperationState.prepared || state == TavernAuthoringOperationState.adopted,
      issue: issue == null
          ? null
          : TavernAuthoringIssue(type: issue['type']! as String, message: issue['message']! as String),
    );
  }

  TavernAuthoringOperation _authoringOperationRow(Row row) {
    final receipt = _authoringReceiptRow(row);
    final texts = <int, String>{};
    Map<String, Object?> snapshot(String column, String idColumn) {
      final value = ChatStore._map(row[column]);
      final id = row[idColumn] as int?;
      if (id != null) {
        value['rawText'] = texts.putIfAbsent(
          id,
          () => ChatStore._unguardText(
            _db.select('SELECT char(1) || raw_text AS raw_text FROM authoring_payloads WHERE payload_id = ?', [
              id,
            ]).single['raw_text'],
          )!,
        );
      }
      return value;
    }

    final before = snapshot('before_json', 'before_raw_text_id');
    final after = snapshot('after_json', 'after_raw_text_id');
    final request = ChatStore._map(row['request_json']);
    if (row['request_uses_after'] == 1) request['after'] = Map<String, Object?>.of(after);
    return TavernAuthoringOperation(
      domainId: receipt.domainId,
      operationId: receipt.operationId,
      physicalResourceId: receipt.physicalResourceId,
      state: receipt.state,
      adoptedRevision: receipt.adoptedRevision,
      historyPending: receipt.historyPending,
      issue: receipt.issue,
      request: request,
      before: before,
      after: after,
      createdAt: ChatStore._date(row['created_at']),
      updatedAt: ChatStore._date(row['updated_at']),
    );
  }
}

/// Shared read-only probe for an open owner and a closed root. It does not
/// create tables, migrate a database, or guess an outcome from file contents.
({String? domainId, bool hasPending, Set<String> protectedArtifacts}) inspectAuthoringDatabase(Database database) {
  if (database.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'authoring_domain'").isEmpty) {
    return (domainId: null, hasPending: false, protectedArtifacts: <String>{});
  }
  final domains = database.select('SELECT domain_id FROM authoring_domain WHERE singleton = 1');
  final domainId = domains.isEmpty ? null : domains.single['domain_id'] as String;
  final operations = database.select(
    "SELECT domain_id, char(1) || operation_id AS operation_id, artifacts_json "
    "FROM authoring_operations WHERE state IN ('prepared', 'unconfirmed')",
  );
  final pending = <(String, String)>{};
  final artifacts = <String>{};
  for (final operation in operations) {
    pending.add((operation['domain_id'] as String, ChatStore._unguardText(operation['operation_id'])!));
    artifacts.addAll((jsonDecode(operation['artifacts_json'] as String) as List<Object?>).cast<String>());
  }
  for (final resource in database.select(
    'SELECT char(1) || pending_operation_id AS operation_id '
    'FROM authoring_resources WHERE pending_operation_id IS NOT NULL',
  )) {
    if (domainId == null || !pending.contains((domainId, ChatStore._unguardText(resource['operation_id'])!))) {
      throw const FormatException('An authoring pending resource has no unresolved operation.');
    }
  }
  return (domainId: domainId, hasPending: operations.isNotEmpty, protectedArtifacts: artifacts);
}

const _schemaV11 = r'''
CREATE TABLE authoring_domain (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  domain_id TEXT NOT NULL
);
CREATE TABLE authoring_resources (
  physical_resource_id TEXT PRIMARY KEY,
  revision INTEGER NOT NULL,
  present INTEGER NOT NULL,
  raw_text TEXT,
  identity_text TEXT,
  pending_operation_id TEXT
);
CREATE TABLE authoring_operations (
  domain_id TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  physical_resource_id TEXT NOT NULL,
  request_json TEXT NOT NULL,
  base_revision INTEGER NOT NULL,
  before_json TEXT NOT NULL,
  after_json TEXT NOT NULL,
  artifacts_json TEXT NOT NULL,
  state TEXT NOT NULL,
  adopted_revision INTEGER,
  issue_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (domain_id, operation_id),
  UNIQUE (domain_id, physical_resource_id, adopted_revision)
);
''';

const _authoringPayloadSchema = r'''
CREATE TABLE authoring_payloads (
  payload_id INTEGER PRIMARY KEY,
  raw_text TEXT NOT NULL
);
ALTER TABLE authoring_resources ADD COLUMN raw_text_id INTEGER REFERENCES authoring_payloads(payload_id);
ALTER TABLE authoring_operations ADD COLUMN before_raw_text_id INTEGER REFERENCES authoring_payloads(payload_id);
ALTER TABLE authoring_operations ADD COLUMN after_raw_text_id INTEGER REFERENCES authoring_payloads(payload_id);
ALTER TABLE authoring_operations ADD COLUMN request_uses_after INTEGER NOT NULL DEFAULT 0;
CREATE INDEX authoring_operations_pending ON authoring_operations (state, domain_id, operation_id, artifacts_json);
CREATE INDEX authoring_resources_pending ON authoring_resources (pending_operation_id);
CREATE INDEX authoring_resources_payload ON authoring_resources (raw_text_id);
CREATE INDEX authoring_operations_before_payload ON authoring_operations (before_raw_text_id);
CREATE INDEX authoring_operations_after_payload ON authoring_operations (after_raw_text_id);
''';
