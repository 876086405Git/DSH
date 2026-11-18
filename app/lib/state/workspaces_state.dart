// Workspaces of the active host, mirroring the official sidebar
// (`dsh-client-ui-workspace` over `dsh-api-workspace-controller`):
//
// * the Host owns the registry: folders, titles, order, which conversations
//   belong where (`Workspace.sessionIds`) and the pinned conversations
//   (`workspace/follow`, a baseline then increments);
// * the phone keeps its own view of it per host (`WorkspacePrefs`): the
//   workspace the drawer shows, pinned workspaces, groups and the folders
//   picked recently. The Host has no pin or group for a workspace, so these
//   stay on this phone.

import '../runtime/container_paths.dart';

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import 'hosts_state.dart';
import 'read_list_cache.dart';
import 'read_list_identity.dart';

// ── Host registry ────────────────────────────────────────────────────────────

enum WorkspacesStatus {
  /// No connection to a host.
  offline,

  /// Connected, waiting for the first baseline.
  loading,
  ready,

  /// The host refused `workspace/follow` before any baseline.
  failed,
}

/// What the active host reports about its workspaces.
class WorkspacesState {
  const WorkspacesState({
    this.status = WorkspacesStatus.offline,
    this.workspaces = const [],
    this.pinnedSessionIds = const [],
    this.archivedSessionIds = const [],
  });

  final WorkspacesStatus status;

  /// Registry order (newest first unless reordered elsewhere).
  final List<Workspace> workspaces;

  /// Pinned conversations, most recently pinned first.
  final List<String> pinnedSessionIds;
  final List<String> archivedSessionIds;

  bool get ready => status == WorkspacesStatus.ready;

  Workspace? byId(String? id) {
    if (id == null) return null;
    for (final w in workspaces) {
      if (w.workspaceId == id) return w;
    }
    return null;
  }

  WorkspacesState copyWith({
    WorkspacesStatus? status,
    List<Workspace>? workspaces,
    List<String>? pinnedSessionIds,
    List<String>? archivedSessionIds,
  }) => WorkspacesState(
    status: status ?? this.status,
    workspaces: workspaces ?? this.workspaces,
    pinnedSessionIds: pinnedSessionIds ?? this.pinnedSessionIds,
    archivedSessionIds: archivedSessionIds ?? this.archivedSessionIds,
  );
}

/// Follows `workspace/follow` on the active connection and runs the
/// registry mutations. Like the official client model: a newer row (by
/// `updatedAt`) wins over an older one, the stream's order wins over unary
/// replies, and a removed workspace never comes back from late data.
class WorkspacesController extends Notifier<WorkspacesState> {
  final Map<String, Workspace> _rows = {};
  List<String> _order = const [];
  final Set<String> _removed = {};
  DshClient? _client;
  ReadListIdentity? _identity;

  @override
  WorkspacesState build() {
    final r = ref;
    _rows.clear();
    _order = const [];
    _removed.clear();
    final conn = r.watch(readListLiveConnectionProvider);
    _client = conn?.client;
    _identity = conn == null ? null : r.watch(readListIdentityProvider);
    if (conn == null) return const WorkspacesState();
    final sub = conn.client.watchWorkspaces().listen(
      (update) {
        if (r.mounted) _onFrame(update);
      },
      onError: (Object _) {
        if (r.mounted && !state.ready) state = state.copyWith(status: WorkspacesStatus.failed);
      },
    );
    ref.onDispose(() => unawaited(sub.cancel()));
    return const WorkspacesState(status: WorkspacesStatus.loading);
  }

  void _onFrame(WorkspaceUpdate update) {
    final full = update is WorkspaceBaseline ? update : workspaceReplaceFrame(update);
    if (full != null) {
      _rows
        ..clear()
        ..addEntries(full.workspaces.map((w) => MapEntry(w.workspaceId, w)));
      _order = [for (final w in full.workspaces) w.workspaceId];
      _emit(status: WorkspacesStatus.ready, pinned: full.pinnedSessionIds, archived: full.archivedSessionIds);
      return;
    }
    switch (update) {
      case WorkspaceUpsert(:final workspace):
        _upsert(workspace, fromStream: true);
      case WorkspaceRemoved(:final workspaceId):
        _drop(workspaceId);
      case WorkspaceOrder(:final workspaceIds):
        _order = List.of(workspaceIds);
      case WorkspacePinnedUpdate(:final pinnedSessionIds):
        return _emit(pinned: pinnedSessionIds);
      case WorkspaceArchivedUpdate(:final archivedSessionIds):
        return _emit(archived: archivedSessionIds);
      default:
        return;
    }
    _emit();
  }

  void _upsert(Workspace w, {bool fromStream = false}) {
    if (w.workspaceId.isEmpty || _removed.contains(w.workspaceId)) return;
    final old = _rows[w.workspaceId];
    if (old != null && !fromStream && _isOlder(w, old)) return;
    _rows[w.workspaceId] = w;
    // New registrations go to the front, like the Host's own order frame.
    if (!_order.contains(w.workspaceId)) _order = [w.workspaceId, ..._order];
  }

  static bool _isOlder(Workspace a, Workspace b) =>
      a.updatedAt != null && b.updatedAt != null && a.updatedAt!.isBefore(b.updatedAt!);

  void _drop(String id) {
    _removed.add(id);
    _rows.remove(id);
    _order = [
      for (final o in _order)
        if (o != id) o,
    ];
  }

  void _emit({WorkspacesStatus? status, List<String>? pinned, List<String>? archived}) {
    final ordered = [
      for (final id in _order) ?_rows[id],
      // Rows the order hasn't caught up with yet.
      for (final w in _rows.values)
        if (!_order.contains(w.workspaceId)) w,
    ];
    final next = state.copyWith(
      status: status,
      workspaces: ordered,
      pinnedSessionIds: pinned,
      archivedSessionIds: archived,
    );
    state = ref.read(readListCacheProvider).stamp(next, _identity, _requireClient);
  }

  DshClient get _requireClient => _client ?? (throw const DshTransportException('not connected'));

  /// Registers [path] (an existing absolute folder) or returns the workspace
  /// that already has it.
  Future<Workspace> add(String path) async {
    final r = ref;
    final result = await _requireClient.createWorkspace(path);
    if (!r.mounted) return result.workspace;
    _removed.remove(result.workspace.workspaceId);
    _upsert(result.workspace);
    _emit();
    return result.workspace;
  }

  Future<Workspace> rename(String workspaceId, String title) async {
    final r = ref;
    final w = await _requireClient.renameWorkspace(workspaceId, title);
    if (!r.mounted) return w;
    _upsert(w);
    _emit();
    return w;
  }

  /// Unregisters a workspace; its folder and conversations stay.
  Future<void> remove(String workspaceId) async {
    final r = ref;
    await _requireClient.deleteWorkspace(workspaceId);
    if (!r.mounted) return;
    _drop(workspaceId);
    _emit();
    await ref.read(workspacePrefsProvider.notifier).forget(workspaceId);
  }

  Future<void> pinSession(String sessionId) async {
    final r = ref;
    final pinned = await _requireClient.pinSession(sessionId);
    if (r.mounted) _emit(pinned: pinned);
  }

  Future<void> unpinSession(String sessionId) async {
    final r = ref;
    final pinned = await _requireClient.unpinSession(sessionId);
    if (r.mounted) _emit(pinned: pinned);
  }
}

final workspacesProvider = NotifierProvider<WorkspacesController, WorkspacesState>(WorkspacesController.new);

// ── This phone's view, per host ──────────────────────────────────────────────

class WorkspacePrefs {
  const WorkspacePrefs({
    this.loaded = false,
    this.selected,
    this.pinned = const [],
    this.groups = const {},
    this.recent = const [],
  });

  factory WorkspacePrefs.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    final groups = map['groups'];
    return WorkspacePrefs(
      loaded: true,
      selected: map['selected'] is String ? map['selected'] as String : null,
      pinned: _strings(map['pinned']),
      groups: {
        if (groups is Map)
          for (final MapEntry(:key, :value) in groups.entries)
            if (key is String && value is String && value.trim().isNotEmpty) key: value.trim(),
      },
      recent: _strings(map['recent']),
    );
  }

  static List<String> _strings(Object? v) => v is List ? v.whereType<String>().toList() : const [];

  final bool loaded;

  /// The workspace the drawer shows; null is 全部对话.
  final String? selected;

  /// Pinned workspace ids, most recently pinned first.
  final List<String> pinned;

  /// Workspace id → group name.
  final Map<String, String> groups;

  /// Folders picked recently, newest first.
  final List<String> recent;

  static const maxRecent = 4;

  Map<String, Object?> toJson() => {'selected': ?selected, 'pinned': pinned, 'groups': groups, 'recent': recent};

  WorkspacePrefs copyWith({
    String? Function()? selected,
    List<String>? pinned,
    Map<String, String>? groups,
    List<String>? recent,
  }) => WorkspacePrefs(
    loaded: loaded,
    selected: selected == null ? this.selected : selected(),
    pinned: pinned ?? this.pinned,
    groups: groups ?? this.groups,
    recent: recent ?? this.recent,
  );
}

/// [WorkspacePrefs] of the active host, in shared preferences.
class WorkspacePrefsController extends Notifier<WorkspacePrefs> {
  String _key = '';
  Future<void> _loading = Future.value();

  /// Preferences key of [host]'s view.
  static String keyFor(HostRef host) => 'workspaces.${host.kind.name}.${host.id}';

  @override
  WorkspacePrefs build() {
    final key = keyFor(ref.watch(activeHostProvider));
    _key = key;
    _loading = _load(key, ref.read(activeHostProvider).isLocal);
    return const WorkspacePrefs();
  }

  /// The selected workspace id once the stored view has loaded.
  Future<String?> selection() async {
    await _loading;
    return state.selected;
  }

  Future<void> _load(String key, bool local) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      var restored = raw == null ? const WorkspacePrefs(loaded: true) : WorkspacePrefs.fromJson(jsonDecode(raw));
      if (local && ContainerPaths.enabled) {
        final paths = await ContainerPaths.load();
        restored = _relocated(restored, paths);
      }
      // The provider may have been disposed while prefs loaded.
      if (!ref.mounted || _key != key || state.loaded) return;
      state = restored;
      if (local && ContainerPaths.enabled && raw != null) {
        final migrated = jsonEncode(restored.toJson());
        if (migrated != raw) await prefs.setString(key, migrated);
      }
    } catch (_) {
      // No preferences backend (tests) or a damaged entry: start empty.
      if (ref.mounted && _key == key && !state.loaded) state = const WorkspacePrefs(loaded: true);
    }
  }

  static WorkspacePrefs _relocated(WorkspacePrefs restored, ContainerPaths paths) {
    // Retained workspace settings win; aliases only fill missing groups.
    final groups = {
      for (final entry in restored.groups.entries)
        if (paths.workspaceId(entry.key) == entry.key) entry.key: entry.value,
    };
    for (final entry in restored.groups.entries) {
      groups.putIfAbsent(paths.workspaceId(entry.key), () => entry.value);
    }
    return restored.copyWith(
      selected: () => restored.selected == null ? null : paths.workspaceId(restored.selected!),
      pinned: {for (final id in restored.pinned) paths.workspaceId(id)}.toList(),
      groups: groups,
      recent: [for (final path in restored.recent) paths.guestPath(path)],
    );
  }

  /// Apply the newly committed marker before the local connection is published.
  Future<void> relocate(ContainerPaths paths) async {
    final key = _key;
    await _loading;
    if (!ref.mounted || _key != key || !ref.read(activeHostProvider).isLocal) return;
    final next = _relocated(state, paths);
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(next.toJson()));
    } catch (_) {
      // The migrated in-memory selection still precedes connection publication.
    }
  }

  Future<void> _save(WorkspacePrefs next) async {
    final key = _key;
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(next.toJson()));
    } catch (_) {
      // Kept in memory for this run.
    }
  }

  /// Shows [workspaceId]'s conversations in the drawer (null: all) and starts
  /// new conversations there.
  Future<void> select(String? workspaceId) => _save(state.copyWith(selected: () => workspaceId));

  Future<void> setPinned(String workspaceId, bool pinned) => _save(
    state.copyWith(
      pinned: [
        if (pinned) workspaceId,
        for (final id in state.pinned)
          if (id != workspaceId) id,
      ],
    ),
  );

  /// Puts [workspaceId] in [group] (trimmed); null or blank ungroups it.
  Future<void> setGroup(String workspaceId, String? group) {
    final name = group?.trim() ?? '';
    final groups = Map.of(state.groups)..remove(workspaceId);
    if (name.isNotEmpty) groups[workspaceId] = name;
    return _save(state.copyWith(groups: groups));
  }

  /// Remembers a folder the user picked from.
  Future<void> remember(String folder) => _save(
    state.copyWith(
      recent: [
        folder,
        for (final p in state.recent)
          if (p != folder) p,
      ].take(WorkspacePrefs.maxRecent).toList(),
    ),
  );

  /// Drops everything about a removed workspace.
  Future<void> forget(String workspaceId) => _save(
    state.copyWith(
      selected: () => state.selected == workspaceId ? null : state.selected,
      pinned: [
        for (final id in state.pinned)
          if (id != workspaceId) id,
      ],
      groups: Map.of(state.groups)..remove(workspaceId),
    ),
  );
}

final workspacePrefsProvider = NotifierProvider<WorkspacePrefsController, WorkspacePrefs>(WorkspacePrefsController.new);

// ── Derived views ────────────────────────────────────────────────────────────

/// The workspace the drawer shows and new conversations start in; null for
/// 全部对话 (or while the selection isn't on the host's list).
final selectedWorkspaceProvider = Provider<Workspace?>((ref) {
  final selected = ref.watch(workspacePrefsProvider.select((p) => p.selected));
  if (selected == null) return null;
  return ref.watch(workspacesProvider).byId(selected);
});

/// Id of [selectedWorkspaceProvider], for `session/create`.
final selectedWorkspaceIdProvider = Provider<String?>((ref) => ref.watch(selectedWorkspaceProvider)?.workspaceId);

/// Whether the drawer should wait before listing: a workspace is selected but
/// the host's registry hasn't arrived yet (avoids flashing every conversation).
final workspaceFilterPendingProvider = Provider<bool>((ref) {
  final prefs = ref.watch(workspacePrefsProvider);
  final status = ref.watch(workspacesProvider.select((s) => s.status));
  if (!prefs.loaded) return status != WorkspacesStatus.offline;
  return prefs.selected != null && status == WorkspacesStatus.loading;
});

enum WorkspaceSectionKind { pinned, group, rest }

/// One block of the workspace list: 置顶, a group, or the rest.
class WorkspaceSection {
  const WorkspaceSection(this.kind, this.title, this.items);

  final WorkspaceSectionKind kind;

  /// Null for the untitled block when there are no pins or groups.
  final String? title;
  final List<Workspace> items;
}

/// Pinned first, then each group (in the order its first member appears),
/// then the rest — the host's order inside each block.
List<WorkspaceSection> workspaceSections(List<Workspace> workspaces, WorkspacePrefs prefs) {
  final pinnedIds = prefs.pinned.toSet();
  final pinned = [
    for (final w in workspaces)
      if (pinnedIds.contains(w.workspaceId)) w,
  ];
  final groups = <String, List<Workspace>>{};
  final rest = <Workspace>[];
  for (final w in workspaces) {
    if (pinnedIds.contains(w.workspaceId)) continue;
    final group = prefs.groups[w.workspaceId];
    if (group == null) {
      rest.add(w);
    } else {
      groups.putIfAbsent(group, () => []).add(w);
    }
  }
  final titled = pinned.isNotEmpty || groups.isNotEmpty;
  return [
    if (pinned.isNotEmpty) WorkspaceSection(WorkspaceSectionKind.pinned, appL10n.commonPin, pinned),
    for (final MapEntry(:key, :value) in groups.entries) WorkspaceSection(WorkspaceSectionKind.group, key, value),
    if (rest.isNotEmpty) WorkspaceSection(WorkspaceSectionKind.rest, titled ? appL10n.commonOther : null, rest),
  ];
}

final workspaceSectionsProvider = Provider<List<WorkspaceSection>>((ref) {
  return workspaceSections(ref.watch(workspacesProvider).workspaces, ref.watch(workspacePrefsProvider));
});

/// Group names in use, in list order.
final workspaceGroupsProvider = Provider<List<String>>((ref) {
  final prefs = ref.watch(workspacePrefsProvider);
  final names = <String>{};
  for (final w in ref.watch(workspacesProvider).workspaces) {
    if (prefs.groups[w.workspaceId] case final g?) names.add(g);
  }
  return names.toList();
});

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Title the official client shows for the first-use workspace it creates
/// (`DEFAULT_WORKSPACE_DIRECTORY`), in Chinese.
String get defaultWorkspaceTitle => appL10n.stateDefaultWorkspace;

/// A workspace's display title: the stored title, the localized default for
/// the first-use workspace, else the folder's name.
String workspaceTitle(Workspace w) {
  final title = w.title.trim();
  if (title == 'default-workspace') return defaultWorkspaceTitle;
  if (title.isNotEmpty) return title;
  final parts = w.path.split('/').where((p) => p.isNotEmpty);
  return parts.isEmpty ? w.path : parts.last;
}

/// Conversations of [w] among [visible] (the drawer's list: no archived,
/// blank or subagent conversations).
int workspaceConversationCount(Workspace w, Iterable<String> visible) {
  final members = w.sessionIds.toSet();
  return visible.where(members.contains).length;
}

/// The workspace used last: the one whose conversation moved most recently,
/// else the one created last. The official client's `recentWorkspace`.
Workspace? recentWorkspace(List<Workspace> workspaces, Iterable<SessionSummary> sessions) {
  final updated = {for (final s in sessions) s.sessionId: s.updatedAt};
  Workspace? recent;
  DateTime? recentTime;
  for (final w in workspaces) {
    DateTime? latest;
    for (final id in w.sessionIds) {
      final at = updated[id];
      if (at != null && (latest == null || at.isAfter(latest))) latest = at;
    }
    latest ??= w.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    if (recentTime == null || latest.isAfter(recentTime)) {
      recent = w;
      recentTime = latest;
    }
  }
  return recent;
}

/// The workspace a new conversation starts in: the drawer's selection,
/// checked against the host's list once that has arrived.
Future<String?> workspaceForNewSession(Ref ref) async {
  final selected = await ref.read(workspacePrefsProvider.notifier).selection();
  if (selected == null) return null;
  final registry = ref.read(workspacesProvider);
  return registry.ready ? registry.byId(selected)?.workspaceId : selected;
}

/// Creates a conversation in [workspaceId] when one is selected, else in
/// [cwd] (null lets the host pick). Falls back to [cwd] if the workspace was
/// removed in the meantime.
Future<SessionCreated> createSessionInWorkspace(
  DshClient client,
  String? workspaceId, {
  String? cwd,
  void Function()? checkCurrent,
}) async {
  checkCurrent?.call();
  if (workspaceId == null) return client.createSession(cwd: cwd);
  try {
    return await client.createSession(workspaceId: workspaceId);
  } on DshRemoteException catch (e) {
    if (e.code != WorkspaceErrors.notFound) rethrow;
    checkCurrent?.call();
    return client.createSession(cwd: cwd);
  }
}
