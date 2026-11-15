// OHOS protocol v1: folder selection/authorization only, no engine workspace admission.
enum WorkspaceAuthorization {
  selected,
  activated,
  needsRestore,
  needsActivation,
  needsReauthorization,
  needsRevalidation,
}

enum WorkspacePersistence { unknown, persisted, absent, unavailable }

enum WorkspaceNativeGrant { unattached, ready, draining, drained, quarantined }

enum WorkspacePersistencePermission { unknown, granted, denied }

Map<Object?, Object?> _map(Object? value) {
  if (value is! Map) {
    throw const FormatException('Invalid authorized workspace response');
  }
  return Map<Object?, Object?>.from(value);
}

T _enum<T extends Enum>(List<T> values, Object? value) {
  for (final item in values) {
    if (item.name == value) return item;
  }
  throw const FormatException('Unknown authorized workspace state');
}

void _protocol(Map<Object?, Object?> value) {
  if (value['protocol'] != 1 || value['engineAttached'] != false) {
    throw const FormatException('Unsupported authorized workspace protocol');
  }
}

class AuthorizedWorkspaceCapabilities {
  const AuthorizedWorkspaceCapabilities._(
    this.available,
    this.folderSelection,
    this.folderAuthorization,
    this.persistencePermission,
  );
  const AuthorizedWorkspaceCapabilities.unavailable()
    : this._(false, false, false, WorkspacePersistencePermission.unknown);
  factory AuthorizedWorkspaceCapabilities.fromChannel(Object? raw) {
    final value = _map(raw);
    _protocol(value);
    if (value['folderSelection'] is! bool ||
        value['folderAuthorization'] is! bool) {
      throw const FormatException('Invalid workspace capabilities');
    }
    return AuthorizedWorkspaceCapabilities._(
      true,
      value['folderSelection'] as bool,
      value['folderAuthorization'] as bool,
      _enum(
        WorkspacePersistencePermission.values,
        value['persistencePermission'],
      ),
    );
  }
  final bool available;
  final bool folderSelection;
  final bool folderAuthorization;
  final WorkspacePersistencePermission persistencePermission;
  bool get engineAttached => false;
}

class AuthorizedWorkspace {
  const AuthorizedWorkspace._(
    this.id,
    this.uri,
    this.name,
    this.candidatePath,
    this.generation,
    this.authorization,
    this.persistence,
    this.nativeGrant,
    this.nativeGeneration,
    this.nativeKey,
  );
  factory AuthorizedWorkspace.fromChannel(Object? raw) {
    final value = _map(raw);
    if (value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        value['uri'] is! String ||
        value['name'] is! String ||
        (value['candidatePath'] != null && value['candidatePath'] is! String) ||
        value['generation'] is! int ||
        (value['generation'] as int) < 0 ||
        value['engineAttached'] != false ||
        value['nodeAccess'] != 'unverified' ||
        value['nativeGeneration'] is! int ||
        (value['nativeGeneration'] as int) < 0 ||
        (value['nativeKey'] != null && value['nativeKey'] is! String)) {
      throw const FormatException('Invalid authorized workspace record');
    }
    return AuthorizedWorkspace._(
      value['id'] as String,
      value['uri'] as String,
      value['name'] as String,
      value['candidatePath'] as String?,
      value['generation'] as int,
      _enum(WorkspaceAuthorization.values, value['authorization']),
      _enum(WorkspacePersistence.values, value['persistence']),
      _enum(WorkspaceNativeGrant.values, value['nativeGrant']),
      value['nativeGeneration'] as int,
      value['nativeKey'] as String?,
    );
  }
  final String id;

  /// Trusted App data only; never an authorization token for the Agent.
  final String uri;
  final String name;
  final String? candidatePath;
  final int generation;
  final WorkspaceAuthorization authorization;
  final WorkspacePersistence persistence;
  final WorkspaceNativeGrant nativeGrant;
  final int nativeGeneration;

  /// Identity only: cannot create a native lease or bypass task policy.
  final String? nativeKey;

  /// Coordinates for DSH's existing FD-backed file provider, never a host path
  /// or an authorization token. The engine still checks the current native
  /// generation and each task's policy; a saved snapshot cannot renew a lease.
  String? get logicalRoot {
    if (nativeGrant != WorkspaceNativeGrant.ready ||
        generation <= 0 ||
        generation != nativeGeneration ||
        (authorization != WorkspaceAuthorization.selected &&
            authorization != WorkspaceAuthorization.activated) ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(id)) {
      return null;
    }
    return '/workspaces/$id';
  }

  bool get engineAttached => false;
  String get nodeAccess => 'unverified';
}

class AuthorizedWorkspacesSnapshot {
  const AuthorizedWorkspacesSnapshot._(
    this.bootId,
    this.workspaces,
    this.osGrantChanged,
  );
  factory AuthorizedWorkspacesSnapshot.fromChannel(Object? raw) {
    final value = _map(raw);
    _protocol(value);
    if (value['bootId'] is! String ||
        (value['bootId'] as String).isEmpty ||
        value['workspaces'] is! List ||
        (value.containsKey('osGrantChanged') &&
            value['osGrantChanged'] != false)) {
      throw const FormatException('Invalid workspace snapshot');
    }
    final entries = (value['workspaces'] as List)
        .map(AuthorizedWorkspace.fromChannel)
        .toList();
    if (entries.map((entry) => entry.id).toSet().length != entries.length) {
      throw const FormatException('Duplicate workspace identity');
    }
    return AuthorizedWorkspacesSnapshot._(
      value['bootId'] as String,
      List.unmodifiable(entries),
      value['osGrantChanged'] as bool?,
    );
  }
  final String bootId;
  final List<AuthorizedWorkspace> workspaces;

  /// Present and false for local forget; it must not be displayed as OS revocation.
  final bool? osGrantChanged;
  bool get engineAttached => false;
}

class AuthorizedWorkspaceFailure implements Exception {
  const AuthorizedWorkspaceFailure(this.code, this.message, {this.details});
  final String code;
  final String message;
  final Object? details;
  @override
  String toString() => 'AuthorizedWorkspaceFailure($code)';
}

typedef AuthorizedWorkspaceInvoke = Future<Object?> Function(
  String method,
  Map<String, Object?> arguments,
);

/// Data/transport layer only. UI must supply the user's current foreground gesture.
class AuthorizedWorkspacesClient {
  const AuthorizedWorkspacesClient(this._invoke);
  final AuthorizedWorkspaceInvoke _invoke;
  Future<AuthorizedWorkspaceCapabilities> capabilities() async =>
      AuthorizedWorkspaceCapabilities.fromChannel(
        await _invoke('capabilities', const {}),
      );
  Future<AuthorizedWorkspacesSnapshot> list() => _snapshot('list', const {});
  Future<AuthorizedWorkspacesSnapshot> select({required bool userGesture}) =>
      _snapshot('select', {'userGesture': userGesture});
  Future<AuthorizedWorkspacesSnapshot> attach(
    String id, {
    required bool userGesture,
  }) => _change('attach', id, userGesture);
  Future<AuthorizedWorkspacesSnapshot> persist(
    String id, {
    required bool userGesture,
  }) => _change('persist', id, userGesture);
  Future<AuthorizedWorkspacesSnapshot> activate(
    String id, {
    required bool userGesture,
  }) => _change('activate', id, userGesture);
  Future<AuthorizedWorkspacesSnapshot> deactivate(
    String id, {
    required bool userGesture,
  }) => _change('deactivate', id, userGesture);
  Future<AuthorizedWorkspacesSnapshot> revoke(
    String id, {
    required bool userGesture,
  }) => _change('revoke', id, userGesture);
  Future<AuthorizedWorkspacesSnapshot> forget(
    String id, {
    required bool userGesture,
  }) => _change('forget', id, userGesture);
  Future<void> cancel() async {
    await _invoke('cancel', const {});
  }

  Future<AuthorizedWorkspacesSnapshot> _change(
    String method,
    String id,
    bool gesture,
  ) => _snapshot(method, {'id': id, 'userGesture': gesture});
  Future<AuthorizedWorkspacesSnapshot> _snapshot(
    String method,
    Map<String, Object?> arguments,
  ) async => AuthorizedWorkspacesSnapshot.fromChannel(
    await _invoke(method, arguments),
  );
}
