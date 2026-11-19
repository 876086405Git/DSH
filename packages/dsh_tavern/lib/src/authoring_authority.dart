import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'authoring.dart';
import 'store/chat_store.dart';

final class AuthoringResourceSnapshot {
  const AuthoringResourceSnapshot({required this.present, this.rawText, this.identityText});
  factory AuthoringResourceSnapshot.fromJson(Map<String, Object?> value) => AuthoringResourceSnapshot(
    present: value['present']! as bool,
    rawText: value['rawText'] as String?,
    identityText: value['identityText'] as String?,
  );

  final bool present;
  final String? rawText;
  final String? identityText;
  Map<String, Object?> toJson() => {'present': present, 'rawText': rawText, 'identityText': identityText};

  bool sameAs(AuthoringResourceSnapshot other) =>
      present == other.present && rawText == other.rawText && identityText == other.identityText;
}

final class AuthoringWriteRequest {
  const AuthoringWriteRequest({
    required this.domainId,
    required this.operationId,
    required this.physicalResourceId,
    required this.parameters,
  });
  final String domainId;
  final String operationId;
  final String physicalResourceId;
  final Map<String, Object?> parameters;
}

final class AuthoringExpectation {
  const AuthoringExpectation({required this.revision, required this.before});
  final TavernAuthorityRevision revision;
  final AuthoringResourceSnapshot before;
}

/// These flags record actual returns from SQL COMMIT and the file primitive.
/// They are never inferred by comparing current files to before/after.
final class AuthoringWriteTicket {
  AuthoringWriteTicket({required this.request, required this.before, required this.after, this.artifacts = const []});
  final AuthoringWriteRequest request;
  final AuthoringResourceSnapshot before;
  final AuthoringResourceSnapshot after;
  final List<String> artifacts;
  bool prepared = false;
  bool enteredEffect = false;
  bool knownAdopted = false;
  bool _noChange = false;
  int? _adoptedRevision;
  TavernAuthoringIssue? _issue;
}

final class AuthoringRootState {
  const AuthoringRootState({this.domainId, required this.hasPending, required this.protectedArtifacts});
  final String? domainId;
  final bool hasPending;
  final Set<String> protectedArtifacts;
}

/// Existing ledger evidence, independent of any fresh file read. A null
/// revision means this resource has not been observed by the authority.
final class AuthoringResourceVersion {
  const AuthoringResourceVersion({required this.domainId, this.revision, this.snapshot, this.pendingOperationId});

  final String domainId;
  final int? revision;
  final AuthoringResourceSnapshot? snapshot;
  final String? pendingOperationId;

  bool sameAs(AuthoringResourceVersion other) =>
      domainId == other.domainId &&
      revision == other.revision &&
      pendingOperationId == other.pendingOperationId &&
      (snapshot == null ? other.snapshot == null : other.snapshot != null && snapshot!.sameAs(other.snapshot!));
}

/// Owns durable facts on the engine's existing SQLite connection. The actual
/// character/book queues own ordering; this class has no asynchronous queue.
final class AuthoringAuthority {
  AuthoringAuthority({required this.root, required ChatStore store}) : _store = store {
    if (!ownsRoot(root)) throw ArgumentError('The authority must use this root\'s main database.');
    _store.initializeAuthoringAuthority();
  }

  final Directory root;
  final ChatStore _store;
  final _live = <(String, String), AuthoringWriteTicket>{};
  String get domainId => _store.authoringDomainId;

  bool ownsRoot(Directory candidate) {
    final path = _store.authoringDatabasePath;
    if (path.isEmpty) return false;
    final actual = File(path).resolveSymbolicLinksSync();
    final expected = File('${candidate.path}/tavern.sqlite3').resolveSymbolicLinksSync();
    return Platform.isWindows ? actual.toLowerCase() == expected.toLowerCase() : actual == expected;
  }

  AuthoringWriteRequest newRequest(String resourceId, Map<String, Object?> parameters) => AuthoringWriteRequest(
    domainId: domainId,
    operationId: _store.newAuthoringOperationId(),
    physicalResourceId: resourceId,
    parameters: parameters,
  );

  /// Check before a writer reads a target that an unresolved delete may have
  /// moved away. This preserves the blocking operation's identity on all exits.
  void checkWritable(String resourceId) =>
      _checkPending(resourceId, _store.readAuthoringResourceHead(resourceId)?.pendingOperationId);

  /// Reads only. In particular this does not observe current files, reconcile
  /// a live ticket, or create a version for an unobserved resource.
  AuthoringResourceVersion peek(String resourceId) {
    final current = _store.readAuthoringResource(resourceId);
    return AuthoringResourceVersion(
      domainId: domainId,
      revision: current?.revision,
      snapshot: current == null ? null : AuthoringResourceSnapshot.fromJson(current.snapshot),
      pendingOperationId: current?.pendingOperationId,
    );
  }

  /// Reads a reserved target for SaveAs replay without reconciling that
  /// operation before the caller's complete parameters have been checked.
  AuthoringWriteRequest? recordedRequest(String domainId, String operationId) {
    final live = _live[(domainId, operationId)];
    if (live != null) {
      return live.request;
    }
    final saved = _store.readAuthoringOperationData(domainId, operationId);
    return saved == null
        ? null
        : AuthoringWriteRequest(
            domainId: saved.domainId,
            operationId: saved.operationId,
            physicalResourceId: saved.physicalResourceId,
            parameters: saved.request,
          );
  }

  TavernAuthoringReceipt? replay(AuthoringWriteRequest request) {
    final live = _live[(request.domainId, request.operationId)];
    if (live != null) {
      if (live.request.physicalResourceId != request.physicalResourceId ||
          !_sameAuthoringParameters(live.request.parameters, request.parameters)) {
        throw TavernAuthoringException(
          'operation_conflict',
          'This operation id already has different parameters.',
          physicalResourceId: request.physicalResourceId,
        );
      }
      try {
        _recordKnown(live);
      } catch (_) {
        /* Keep the original live result if recording still fails. */
      }
      return _receipt(live);
    }
    final stored = _store.readAuthoringOperationData(request.domainId, request.operationId);
    if (stored == null) return null;
    _checkRequest(request, stored);
    return readOperation(request.operationId, domainId: request.domainId)!;
  }

  TavernAuthorityRevision observe(String resourceId, AuthoringResourceSnapshot fresh) => _store.transaction(() {
    final current = _store.readAuthoringResource(resourceId);
    _checkPending(resourceId, current?.pendingOperationId);
    var revision = current?.revision ?? 1;
    if (current == null || !AuthoringResourceSnapshot.fromJson(current.snapshot).sameAs(fresh)) {
      if (current != null) revision++;
      _store.putAuthoringResource(
        resourceId,
        revision,
        fresh.toJson(),
        rawTextId: current?.snapshot['rawText'] == fresh.rawText ? current?.rawTextId : null,
      );
    }
    return TavernAuthorityRevision(domainId: domainId, revision: revision);
  });

  /// Returns an existing same-parameter result without admitting another file
  /// effect. Every caller must stop at that return, including the noChange path.
  TavernAuthoringReceipt? prepare(
    AuthoringWriteTicket ticket, {
    AuthoringExpectation? expected,
    void Function()? check,
  }) => _accept(ticket, TavernAuthoringOperationState.prepared, expected: expected, check: check);

  TavernAuthoringReceipt? _accept(
    AuthoringWriteTicket ticket,
    TavernAuthoringOperationState state, {
    AuthoringExpectation? expected,
    void Function()? check,
  }) {
    final request = ticket.request;
    final replayed = replay(request);
    if (replayed != null) return replayed;
    if (request.domainId != domainId) _conflict(request.physicalResourceId);
    // Persist an actually observed external difference even if the following
    // expected-version check rejects this edit. No await separates the two.
    observe(request.physicalResourceId, ticket.before);
    var inserted = false;
    return _store.transaction(
      () {
        final existing = _store.readAuthoringOperationData(request.domainId, request.operationId);
        if (existing != null) {
          _checkRequest(request, existing);
          return existing;
        }
        check?.call();
        final current = _store.readAuthoringResourceHead(request.physicalResourceId)!;
        _checkPending(request.physicalResourceId, current.pendingOperationId);
        if (expected != null &&
            (expected.revision.domainId != domainId ||
                expected.revision.revision != current.revision ||
                !expected.before.sameAs(ticket.before))) {
          _conflict(request.physicalResourceId);
        }
        _store.insertAuthoringOperationData(
          domainId: request.domainId,
          operationId: request.operationId,
          resourceId: request.physicalResourceId,
          parameters: request.parameters,
          baseRevision: current.revision,
          before: ticket.before.toJson(),
          after: ticket.after.toJson(),
          artifacts: ticket.artifacts,
          state: state,
        );
        if (state == TavernAuthoringOperationState.prepared) {
          _store.setAuthoringResourcePending(request.physicalResourceId, request.operationId);
        }
        inserted = true;
        return null;
      },
      onCommitted: () {
        if (inserted) {
          ticket.prepared = true;
          ticket._noChange = state == TavernAuthoringOperationState.noChange;
        }
      },
    );
  }

  TavernAuthoringReceipt adopted(AuthoringWriteTicket ticket) {
    final request = ticket.request;
    int? adoptedRevision;
    _store.transaction(
      () {
        final operation = _store.readAuthoringReceiptData(request.domainId, request.operationId)!;
        if (operation.committed == true) {
          adoptedRevision = operation.adoptedRevision;
          return;
        }
        final current = _store.readAuthoringResourceHead(request.physicalResourceId)!;
        final revision = current.revision + 1;
        adoptedRevision = revision;
        _store.adoptAuthoringResourceData(request.physicalResourceId, revision, request.domainId, request.operationId);
        _store.finishAuthoringOperationData(
          request.domainId,
          request.operationId,
          TavernAuthoringOperationState.adopted,
          adoptedRevision: revision,
          issue: ticket._issue,
        );
      },
      onCommitted: () {
        ticket._adoptedRevision = adoptedRevision;
      },
    );
    return _receipt(ticket);
  }

  TavernAuthoringReceipt notAdopted(
    AuthoringWriteTicket ticket, {
    bool noChange = false,
    AuthoringExpectation? expected,
    void Function()? check,
  }) {
    if (noChange) {
      final existing = _accept(ticket, TavernAuthoringOperationState.noChange, expected: expected, check: check);
      return existing ?? _receipt(ticket);
    }
    _recordNotAdopted(ticket);
    return _receipt(ticket);
  }

  void _recordNotAdopted(AuthoringWriteTicket ticket) {
    final request = ticket.request;
    _store.transaction(
      () {
        final operation = _store.readAuthoringReceiptData(request.domainId, request.operationId)!;
        final state = operation.state == TavernAuthoringOperationState.noChange
            ? TavernAuthoringOperationState.noChange
            : TavernAuthoringOperationState.notAdopted;
        if (operation.state == state &&
            operation.issue?.type == ticket._issue?.type &&
            operation.issue?.message == ticket._issue?.message) {
          return;
        }
        _store.setAuthoringResourcePending(request.physicalResourceId, null);
        _store.finishAuthoringOperationData(request.domainId, request.operationId, state, issue: ticket._issue);
      },
      onCommitted: () {
        _live.remove((request.domainId, request.operationId));
      },
    );
  }

  void _recordUnconfirmed(AuthoringWriteTicket ticket) {
    final request = ticket.request;
    _store.transaction(
      () {
        _store.finishAuthoringOperationData(
          request.domainId,
          request.operationId,
          TavernAuthoringOperationState.unconfirmed,
          issue: ticket._issue,
        );
      },
      onCommitted: () {
        _live.remove((request.domainId, request.operationId));
      },
    );
  }

  TavernAuthoringReceipt publish(AuthoringWriteTicket ticket, {TavernAuthoringIssue? issue}) {
    ticket._issue = issue ?? ticket._issue;
    final request = ticket.request;
    _store.transaction(
      () {
        final current = _store.readAuthoringReceiptData(request.domainId, request.operationId)!;
        final nextIssue = ticket._issue ?? current.issue;
        if (current.state == TavernAuthoringOperationState.published &&
            current.issue?.type == nextIssue?.type &&
            current.issue?.message == nextIssue?.message) {
          return;
        }
        _store.finishAuthoringOperationData(
          request.domainId,
          request.operationId,
          TavernAuthoringOperationState.published,
          adoptedRevision: current.adoptedRevision,
          issue: nextIssue,
        );
      },
      onCommitted: () {
        _live.remove((request.domainId, request.operationId));
      },
    );
    return _receipt(ticket);
  }

  Never fail(AuthoringWriteTicket ticket, Object cause, StackTrace stack) {
    if (!ticket.prepared) Error.throwWithStackTrace(cause, stack);
    ticket._issue = TavernAuthoringIssue(type: cause.runtimeType.toString(), message: cause.toString());
    _live[(ticket.request.domainId, ticket.request.operationId)] = ticket;
    try {
      _recordKnown(ticket);
    } catch (_) {
      // Keep the live file-return fact and original cause. A second journal
      // error changes historyPending, never the known adoption result.
    }
    Error.throwWithStackTrace(
      TavernAuthoringException(
        'resource_write_failed',
        'The resource operation did not finish cleanly.',
        physicalResourceId: ticket.request.physicalResourceId,
        receipt: _receipt(ticket),
        cause: cause,
      ),
      stack,
    );
  }

  void _recordKnown(AuthoringWriteTicket ticket) {
    if (ticket.knownAdopted) {
      adopted(ticket);
      publish(ticket);
    } else if (ticket.enteredEffect) {
      _recordUnconfirmed(ticket);
    } else {
      _recordNotAdopted(ticket);
    }
  }

  void reconcileLiveTickets() {
    for (final ticket in List<AuthoringWriteTicket>.of(_live.values)) {
      try {
        _recordKnown(ticket);
      } catch (_) {
        /* Keep live facts; pendingState decides whether backup is blocked. */
      }
    }
  }

  TavernAuthoringReceipt _receipt(AuthoringWriteTicket ticket) {
    final request = ticket.request;
    final TavernAuthoringReceipt current;
    try {
      current = _store.readAuthoringReceiptData(request.domainId, request.operationId)!;
    } catch (_) {
      // A failed journal read must not replace the original file/marker error
      // or erase a successful return that this live call already witnessed.
      return TavernAuthoringReceipt(
        domainId: request.domainId,
        operationId: request.operationId,
        physicalResourceId: request.physicalResourceId,
        state: ticket._noChange
            ? TavernAuthoringOperationState.noChange
            : ticket.knownAdopted
            ? TavernAuthoringOperationState.adopted
            : ticket.enteredEffect
            ? TavernAuthoringOperationState.unconfirmed
            : TavernAuthoringOperationState.notAdopted,
        adoptedRevision: ticket._adoptedRevision,
        historyPending: true,
        issue: ticket._issue,
      );
    }
    final pending = _live.containsKey((request.domainId, request.operationId));
    final state = ticket.knownAdopted && current.committed != true
        ? TavernAuthoringOperationState.adopted
        : pending && current.state == TavernAuthoringOperationState.prepared
        ? (ticket.enteredEffect ? TavernAuthoringOperationState.unconfirmed : TavernAuthoringOperationState.notAdopted)
        : current.state;
    return TavernAuthoringReceipt(
      domainId: request.domainId,
      operationId: request.operationId,
      physicalResourceId: request.physicalResourceId,
      state: state,
      adoptedRevision: current.adoptedRevision,
      historyPending: pending || current.historyPending,
      issue: ticket._issue ?? current.issue,
    );
  }

  TavernAuthoringOperation? readOperation(String operationId, {required String domainId}) {
    final ticket = _live[(domainId, operationId)];
    if (ticket != null) {
      try {
        _recordKnown(ticket);
      } catch (_) {
        /* The receipt retains the live fact. */
      }
    }
    var current = _store.readAuthoringOperationData(domainId, operationId);
    if (ticket == null && current?.state == TavernAuthoringOperationState.adopted) {
      // The adopted marker itself is durable evidence after reopen. Finishing
      // this journal result never repeats a file effect or repairs an index.
      try {
        _store.transaction(() {
          final saved = _store.readAuthoringReceiptData(domainId, operationId)!;
          if (saved.state == TavernAuthoringOperationState.adopted) {
            _store.finishAuthoringOperationData(
              domainId,
              operationId,
              TavernAuthoringOperationState.published,
              adoptedRevision: saved.adoptedRevision,
              issue: saved.issue,
            );
          }
        });
      } catch (_) {
        /* A failed publish remains queryable as adopted/historyPending. */
      }
      current = _store.readAuthoringOperationData(domainId, operationId);
    }
    if (current == null || ticket == null) return current;
    final receipt = _receipt(ticket);
    return TavernAuthoringOperation(
      domainId: current.domainId,
      operationId: current.operationId,
      physicalResourceId: current.physicalResourceId,
      state: receipt.state,
      adoptedRevision: receipt.adoptedRevision,
      historyPending: receipt.historyPending,
      issue: receipt.issue,
      request: current.request,
      before: current.before,
      after: current.after,
      createdAt: current.createdAt,
      updatedAt: current.updatedAt,
    );
  }

  List<TavernAuthoringRevisionSummary> listRevisions(String resourceId) =>
      _store.listAuthoringRevisionsData(resourceId);

  AuthoringResourceSnapshot? revisionSnapshot(String resourceId, TavernAuthorityRevision revision) {
    final operation = _store.readAuthoringRevisionData(resourceId, revision);
    return operation == null ? null : AuthoringResourceSnapshot.fromJson(operation.after);
  }

  AuthoringRootState pendingState() {
    final state = _store.authoringRootStateData();
    return AuthoringRootState(
      domainId: state.domainId,
      hasPending: state.hasPending,
      protectedArtifacts: state.protectedArtifacts,
    );
  }

  static AuthoringRootState inspectRootReadOnly(Directory root) {
    final file = File('${root.path}/tavern.sqlite3');
    // A failed exists() check can hide an inaccessible ledger. Open read-only
    // first and accept only the platform's actual missing-path error.
    try {
      file.openSync(mode: FileMode.read).closeSync();
    } on PathNotFoundException catch (error) {
      final code = error.osError?.errorCode;
      if (code != 2 && (!Platform.isWindows || code != 3)) rethrow;
      return const AuthoringRootState(hasPending: false, protectedArtifacts: <String>{});
    }
    final database = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      final state = inspectAuthoringDatabase(database);
      return AuthoringRootState(
        domainId: state.domainId,
        hasPending: state.hasPending,
        protectedArtifacts: state.protectedArtifacts,
      );
    } finally {
      database.close();
    }
  }

  void _checkRequest(AuthoringWriteRequest request, TavernAuthoringOperation operation) {
    if (operation.physicalResourceId != request.physicalResourceId ||
        !_sameAuthoringParameters(operation.request, request.parameters)) {
      throw TavernAuthoringException(
        'operation_conflict',
        'This operation id already has different parameters.',
        physicalResourceId: request.physicalResourceId,
      );
    }
  }

  void _checkPending(String resourceId, String? pendingOperationId) {
    if (pendingOperationId != null) {
      throw TavernAuthoringException(
        'pending_operation',
        'This resource has an unresolved file operation.',
        physicalResourceId: resourceId,
        blockedDomainId: domainId,
        blockedOperationId: pendingOperationId,
      );
    }
  }

  Never _conflict(String resourceId) => throw TavernAuthoringException(
    'authority_conflict',
    'The authoritative resource or its domain changed.',
    physicalResourceId: resourceId,
  );
}

bool _sameAuthoringParameters(Object? a, Object? b) {
  if (a is Map<String, Object?> && b is Map<String, Object?>) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _sameAuthoringParameters(a[key], b[key]));
  }
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameAuthoringParameters(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
