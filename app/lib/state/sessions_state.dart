import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../companion/companion_state.dart';
import '../runtime/runtime_state.dart';
import 'connection_state.dart';
import 'hosts_state.dart';
import '../runtime/local_paths.dart';
import 'read_list_cache.dart';
import 'read_list_identity.dart';
import 'settings_state.dart';
import 'workspaces_state.dart';

/// Default working directory for sessions created on the phone.
String get localWorkspaceDir => LocalPaths.workspace;

class ArchiveCommitResult {
  const ArchiveCommitResult(this.archived, this.failed);
  final List<String> archived;
  final List<String> failed;
}

/// An archive waiting out its undo window: nothing reaches the Host before
/// the window ends. [undo] drops it; [commitNow] ends the window early.
class PendingSessionArchive {
  PendingSessionArchive(this.ids);
  final List<String> ids;
  final _window = Completer<void>();
  final _done = Completer<ArchiveCommitResult?>();
  Timer? _timer;
  bool _committing = false;
  bool _retired = false;
  bool _undone = false;

  /// Scheduling it ended an older waiting archive early.
  bool replacedPrevious = false;
  late bool Function() _owned;
  late bool Function() _cancel;
  late bool Function() _commitNow;
  late void Function() _release;
  bool get canUndo => !_window.isCompleted;
  bool get owned => !_retired && _owned();
  Future<void> get windowClosed => _window.future;

  /// The archive's outcome; null when nothing was archived because it was
  /// dropped before sending (撤销, a Host change, a reconnect).
  Future<ArchiveCommitResult?> get done => _done.future;

  /// Drops the plan if nothing has been sent yet.
  bool cancel() => _cancel();

  /// 撤销: [cancel], remembered as the user's choice.
  bool undo() {
    if (!canUndo || _committing) return false;
    _undone = true;
    if (_cancel()) return true;
    _undone = false;
    return false;
  }

  /// Archives now instead of when the window ends: the app is leaving the
  /// screen, or a newer undo notice takes this one's place.
  bool commitNow() => _commitNow();

  /// Dropped with 撤销.
  bool get undone => _undone;

  /// Archiving has started on the Host; it can no longer be taken back.
  bool get sent => _committing;
  void release() => _release();
  void _closeWindow() {
    _timer?.cancel();
    if (!_window.isCompleted) _window.complete();
  }
}

/// A title read through `session/projections` for a row `session/list`
/// served without one, as of the row's `updatedAt`.
typedef SessionTitleRead = ({DateTime updatedAt, String? title, bool? blank});

/// A title read that failed, as of the row's `updatedAt`: the [failures] in a
/// row, and when the row may be asked again.
typedef _TitleFailure = ({DateTime updatedAt, int failures, DateTime retryAt});

/// "Now" for the title reads' retries (tests move it).
final sessionTitleClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Session list of the active host, newest first, refreshed on host events.
///
/// Titles: `session/list` serves a conversation the Host process isn't
/// holding (a cold one) with the title from its projection cache, which the
/// process reads once, when it starts (DSH 0.2.1-rc.4). A conversation
/// another DSH process on the same machine wrote since — the desktop app, the
/// TUI, a headless run, a second `dsh web`; on an SSH host the app's own
/// `dsh web` lives on between connections — comes with no title at all until
/// something opens it. Those rows get their title read
/// (`session/projections`, which doesn't open the conversation), a few at a
/// time, once per change of the row.
class SessionsController extends AsyncNotifier<List<SessionSummary>> {
  Timer? _debounce;
  final _archives = <PendingSessionArchive>{};
  final _archiveLeases = <PendingSessionArchive>{};
  final _deleting = <String>{};
  final _deleted = <String>{};
  static const archiveUndoWindow = Duration(seconds: 4);

  void _retireArchives() {
    for (final pending in _archiveLeases.toList()) {
      pending._retired = true;
      pending._closeWindow();
      if (!pending._done.isCompleted) pending._done.complete(null);
    }
    _archives.clear();
    _archiveLeases.clear();
  }

  int _archiveIntent = 0;
  int _archiveBatchDepth = 0;
  bool get _hasArchivePlans => _archives.isNotEmpty || _archiveLeases.isNotEmpty;

  /// While a list loads, it picks the waiting set up itself.
  void _showArchiveRows() {
    if (_archiveBatchDepth == 0 && ref.mounted && state.hasValue && !state.isLoading) state = AsyncData(_visible());
  }

  HostRef? _host;

  /// Bumped by every build and refresh: only the newest load may land.
  int _loadSeq = 0;
  int _appliedRefreshSeq = 0;
  List<SessionSummary> _all = const [];
  Set<String> _archived = const {};
  ReadListOrigin? _origin;
  Future<List<SessionSummary>>? _buildRead;

  /// A refresh asked for while the build's list was being read: it reads
  /// once more after that one ([refresh]).
  Future<void>? _afterBuild;

  /// A host event in the debounce window changed a conversation.
  bool _debouncedChange = false;

  /// Titles read for rows served without one, by session id (this host).
  final Map<String, SessionTitleRead> _titles = {};

  /// The title reads of the live connection ([_readTitles]): one queue that
  /// every list refills, read [titleReadsAtOnce] at a time across all of them.
  _TitleReads? _titleReads;

  /// Title reads still out, by client, whichever queue started them. A queue
  /// retired by the mux reconnecting doesn't end its reads: they are HTTP
  /// calls the client keeps (an SSH host's tunnel back on the same port and
  /// token keeps its client), each still folding a log on the Host. The next
  /// queue on that client counts them against its [titleReadsAtOnce] until
  /// they come back.
  final Map<DshClient, int> _titleCallsOut = Map.identity();

  /// Rows whose title read failed (the Host or a proxy erring just then), by
  /// session id. Only a read that came back is kept as the row's
  /// ([_titles]): a failed one is asked again by the next list, and failing
  /// again waits [titleRetryAfter], twice that the next time, up to
  /// [titleRetryMax]. A row that changed is asked at once.
  final Map<String, _TitleFailure> _titleFailures = {};

  /// The client that can't read titles this way (an older Host, the relay).
  Object? _titlesUnsupported;
  Timer? _titlesLanded;

  /// Rows read per list: the newest first, the rest on later lists.
  static const titleReadsPerList = 40;

  /// Reads at a time: each one folds a whole conversation log on the Host.
  static const titleReadsAtOnce = 2;

  static const titleRetryAfter = Duration(seconds: 15);
  static const titleRetryMax = Duration(minutes: 10);

  @override
  Future<List<SessionSummary>> build() async {
    final r = ref;
    _retireArchives();
    ref.listen(activeHostProvider, (previous, next) {
      if (previous != next && _hasArchivePlans) {
        _retireArchives();
        _showArchiveRows();
      }
    });
    ref.onDispose(_retireArchives);
    // Which conversation is the companion's is read from preferences after
    // launch: hide it from the drawer as soon as that's known.
    ref.listen(companionSessionFilterProvider, (_, _) {
      if (state.hasValue && !state.isLoading) state = AsyncData(_visible());
    });
    final seq = ++_loadSeq;
    final host = ref.watch(activeHostProvider);
    if (host != _host) {
      // Rows of the previous host never mix into this one's. (Riverpod still
      // shows them as the reload's previous value until the new list lands.)
      _host = host;
      _all = const [];
      _deleted.clear();
      _deleting.clear();
      _archived = const {};
      _origin = null;
      _titles.clear();
      _titleFailures.clear();
      _titlesUnsupported = null;
      _retireTitleReads();
    }
    // Events an earlier build's debounce had gathered land nowhere.
    _debouncedChange = false;
    final conn = ref.watch(readListLiveConnectionProvider);
    // Title reads of a connection that went land nowhere, and what it had
    // queued isn't read; a rebuild on the same connection carries them on.
    if (conn == null || !identical(_titleReads?.client, conn.client)) _retireTitleReads();
    _titleReads?.ref = r;
    if (conn == null) {
      _buildRead = null;
      return r.read(readListCacheProvider).stamp(<SessionSummary>[], null, Object());
    }
    final identity = r.watch(readListIdentityProvider);
    // Only a waiting or sending archive has anything to retire; otherwise a
    // mux state change must not republish the list mid-load.
    final muxChanges = conn.client.mux.states.listen((_) {
      if (!_hasArchivePlans) return;
      _retireArchives();
      _showArchiveRows();
    });
    ref.onDispose(() => unawaited(muxChanges.cancel()));
    final sub = conn.client.hostEvents.listen((event) {
      if (event is SessionAddedEvent ||
          event is SessionRemovedEvent ||
          event is SessionStatusEvent ||
          event is HostReadyEvent) {
        if (_applyInPlace(event)) return;
        // Ready alone changes no conversation: it doesn't read the list a
        // second time behind the one a (re)connection is reading.
        final readyAt = event is HostReadyEvent ? _loadSeq : null;
        _debouncedChange |= event is! HostReadyEvent;
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 400), () {
          final change = _debouncedChange;
          _debouncedChange = false;
          // Only a successful request started after this ready covers it.
          // A pre-ready response, newer pending/failing read or later change
          // still needs the existing recovery path.
          if (!change && readyAt != null && _appliedRefreshSeq == _loadSeq && _appliedRefreshSeq > readyAt) return;
          unawaited(_refresh(afterBuild: change));
        });
      }
    });
    // session/list includes archived sessions; the workspace stream says which.
    final workspaces = conn.client.watchWorkspaces().listen((update) {
      if (!r.mounted) return;
      final archived = switch (update) {
        WorkspaceBaseline(:final archivedSessionIds) => archivedSessionIds,
        WorkspaceArchivedUpdate(:final archivedSessionIds) => archivedSessionIds,
        _ => null,
      };
      if (archived == null) return;
      _archived = archived.toSet();
      // While a list loads, it picks the new set up itself.
      if (state.hasValue && !state.isLoading) state = AsyncData(_visible());
    }, onError: (_) {});
    ref.onDispose(() {
      _debounce?.cancel();
      _titlesLanded?.cancel();
      _titlesLanded = null;
      unawaited(sub.cancel());
      unawaited(workspaces.cancel());
    });
    return _buildRead = _load(r, conn.client, seq, identity);
  }

  Future<List<SessionSummary>> _load(Ref r, DshClient client, int seq, ReadListIdentity? identity) async {
    final List<SessionSummary> sessions;
    _listsOut++;
    try {
      sessions = await client.listSessions();
    } finally {
      _listsOut--;
    }
    if (!r.mounted) return const [];
    if (seq == _loadSeq) {
      // A list already in flight when deletion completed may still contain
      // the old row. Only a server-confirmed deletion adds this host's fence.
      _all = sessions.where((s) => !_deleted.contains(s.sessionId)).toList();
      final cache = r.read(readListCacheProvider);
      cache.stamp(sessions, identity, client);
      _origin = cache.origin(sessions);
      _readTitles(r, client);
    }
    return _visible();
  }

  /// Lists being read. An edge landing meanwhile reads the list once more
  /// instead of being applied in place: the read out may predate it.
  int _listsOut = 0;

  /// Applies a `$events` edge to the rows when the edge says all that
  /// changed, instead of reading every conversation again (`session/list`
  /// has no paging: a remote Host sends all of them, projections and all,
  /// through the Relay on each read). That covers a conversation added or
  /// re-announced (the edge carries its row), a listed conversation starting
  /// a turn, and any edge of a subagent child (hidden here, kept for the
  /// lineage). A turn ending, a removal and a conversation not listed yet
  /// still read the list.
  bool _applyInPlace(HostEvent event) {
    if (_listsOut > 0 || !state.hasValue || state.isLoading) return false;
    final SessionSummary row;
    switch (event) {
      case SessionAddedEvent(:final summary) when summary.sessionId.isNotEmpty:
        row = summary;
      case SessionStatusEvent(:final sessionId, :final running):
        final listed = _all.where((s) => s.sessionId == sessionId).firstOrNull;
        if (listed == null || !(listed.isSubagent || running && !listed.blank)) return false;
        row = listed.copyWith(running: running);
      default:
        return false;
    }
    if (_deleted.contains(row.sessionId)) return true;
    final at = _all.indexWhere((s) => s.sessionId == row.sessionId);
    _all = at < 0 ? [..._all, row] : (List.of(_all)..[at] = row);
    state = AsyncData(_visible());
    return true;
  }

  List<SessionSummary> _visible() {
    final pendingIds = {for (final pending in _archives) ...pending.ids};
    // Her conversation lives in 伙伴小屋, not the drawer.
    final companion = ref.read(companionSessionFilterProvider);
    final host = ref.read(activeHostProvider);
    return ref
        .read(readListCacheProvider)
        .derive(
          _rows()
              .where(
                (s) =>
                    !s.blank &&
                    !s.isSubagent &&
                    !_archived.contains(s.sessionId) &&
                    !pendingIds.contains(s.sessionId) &&
                    !companion(host, s.sessionId),
              )
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
          _origin,
        );
  }

  /// The last `session/list`, with the titles read since ([_readTitles]).
  List<SessionSummary> _rows() => _titles.isEmpty ? _all : [for (final s in _all) _withTitle(s)];

  /// [s] with what was read for it: its title where the list had none (an
  /// older read beats 「未命名」 until the newer one lands), and blank only
  /// while the row is as it was read.
  SessionSummary _withTitle(SessionSummary s) {
    final read = _titles[s.sessionId];
    // A conversation the Host holds is served first-hand.
    if (read == null || s.projectionsKind == 'sequenced') return s;
    final title = read.title?.trim();
    final fill = (s.title?.trim().isEmpty ?? true) && title != null && title.isNotEmpty;
    final blank = read.blank == true && read.updatedAt == s.updatedAt;
    if (!fill && !blank) return s;
    return s.copyWith(
      blank: blank ? true : null,
      projections: fill ? SessionProjections(s.projections.asOfSeq, {...s.projections.values, 'title': title}) : null,
    );
  }

  bool _needsTitle(SessionSummary s, DateTime now) =>
      !s.isSubagent &&
      !s.blank &&
      s.projectionsKind != 'sequenced' &&
      (s.title?.trim().isEmpty ?? true) &&
      !_archived.contains(s.sessionId) &&
      !(_titleReads?.running.contains(s.sessionId) ?? false) &&
      _titles[s.sessionId]?.updatedAt != s.updatedAt &&
      !_waitingToRetry(s, now);

  bool _waitingToRetry(SessionSummary s, DateTime now) {
    final failed = _titleFailures[s.sessionId];
    return failed != null && failed.updatedAt == s.updatedAt && now.isBefore(failed.retryAt);
  }

  /// Queues the titles the list came without, newest first, at most
  /// [titleReadsPerList] (in place of what an earlier list queued); each row
  /// read once until it changes ([_titleFailures]: one that failed again
  /// later). What lands re-emits [state].
  void _readTitles(Ref r, DshClient client) {
    if (identical(_titlesUnsupported, client)) return;
    var reads = _titleReads;
    if (reads == null || !identical(reads.client, client)) {
      reads?.retired = true;
      reads = _titleReads = _TitleReads(client, r, r.read(sessionTitleClockProvider));
    }
    final now = reads.now();
    final queue = _all.where((s) => _needsTitle(s, now)).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (queue.length > titleReadsPerList) queue.length = titleReadsPerList;
    reads.queue
      ..clear()
      ..addAll(queue);
    _nextTitles(reads);
  }

  /// Starts queued reads while fewer than [titleReadsAtOnce] are out on the
  /// client, a retired queue's included ([_titleCallsOut]).
  void _nextTitles(_TitleReads reads) {
    final client = reads.client;
    while (!reads.retired &&
        reads.ref.mounted &&
        (_titleCallsOut[client] ?? 0) < titleReadsAtOnce &&
        reads.queue.isNotEmpty) {
      final row = reads.queue.removeFirst();
      reads.running.add(row.sessionId);
      _titleCallsOut[client] = (_titleCallsOut[client] ?? 0) + 1;
      unawaited(_readTitle(reads, row));
    }
  }

  Future<void> _readTitle(_TitleReads reads, SessionSummary row) async {
    final client = reads.client;
    SessionTitleRead? read;
    var failed = false;
    // The Host can't read titles this way: what [_titlesUnsupported] says
    // once this read turns out to be the current queue's.
    var unsupported = false;
    try {
      final projections = await client.projections(row.sessionId);
      read = (updatedAt: row.updatedAt, title: projections?.title, blank: projections?.blank);
    } on DshRemoteException catch (error) {
      if (error.code == 'METHOD_NOT_ALLOWED' || error.code.endsWith('method-not-found')) {
        unsupported = true;
      } else {
        // `gateway/internal` (the Host couldn't read the log just then) and
        // the like: not the row's answer.
        failed = true;
      }
    } on DshHttpException catch (error) {
      if (error.statusCode == 403 || error.statusCode == 404) {
        unsupported = true;
      } else {
        // A tunnel's or proxy's 5xx.
        failed = true;
      }
    } catch (_) {
      // The connection went: a later list asks again.
    }
    reads.running.remove(row.sessionId);
    final out = (_titleCallsOut[client] ?? 1) - 1;
    if (out > 0) {
      _titleCallsOut[client] = out;
    } else {
      _titleCallsOut.remove(client);
    }
    if (reads.retired) {
      // What it read lands nowhere, a "can't read titles" included (what
      // the queue reading now is answered decides that); its slot goes to
      // that queue if it's on the same client.
      final current = _titleReads;
      if (current != null && identical(current.client, client)) _nextTitles(current);
      return;
    }
    if (unsupported) _titlesUnsupported = client;
    if (failed) _titleFailed(row, reads.now());
    if (read != null) {
      _titleFailures.remove(row.sessionId);
      final before = _titles[row.sessionId];
      _titles[row.sessionId] = read;
      if (read.title != before?.title || read.blank != before?.blank) _titlesChanged(reads.ref);
    }
    if (identical(_titlesUnsupported, client)) {
      reads.queue.clear();
      return;
    }
    _nextTitles(reads);
  }

  /// [row]'s read failed: the first time the next list asks again, after
  /// that it waits longer each time. What was read before stays.
  void _titleFailed(SessionSummary row, DateTime now) {
    final before = _titleFailures[row.sessionId];
    final failures = before != null && before.updatedAt == row.updatedAt ? before.failures + 1 : 1;
    var wait = failures == 1 ? Duration.zero : titleRetryAfter * (1 << (failures - 2).clamp(0, 10));
    if (wait > titleRetryMax) wait = titleRetryMax;
    _titleFailures[row.sessionId] = (updatedAt: row.updatedAt, failures: failures, retryAt: now.add(wait));
  }

  void _retireTitleReads() {
    _titleReads?.retired = true;
    _titleReads = null;
  }

  /// Titles landed: one re-emit for those landing together. A list being
  /// loaded picks them up itself.
  void _titlesChanged(Ref r) {
    _titlesLanded ??= Timer(Duration.zero, () {
      _titlesLanded = null;
      if (!r.mounted) return;
      if (state.hasValue && !state.isLoading) state = AsyncData(_visible());
    });
  }

  /// Archived sessions of the active host, newest first (session search lists
  /// them so they can be found and restored). Changes to the archived set
  /// re-emit [state], so watchers of [sessionsProvider] see them.
  List<SessionSummary> get archivedSessions =>
      _rows().where((s) => !s.blank && !s.isSubagent && _archived.contains(s.sessionId)).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  /// Every row of the last `session/list`, subagent children included (the
  /// lineage in agents_state.dart is built from it). Re-read on [state].
  List<SessionSummary> get allSessions => _rows();

  /// Reads the list again. Asked for while a (re)connection's first list is
  /// being read, it waits for that one and then reads once more: that list
  /// was asked for before the change that wants this refresh (a conversation
  /// added or started meanwhile), which would otherwise wait for the next
  /// event — a new conversation untitled, or missing, until its turn ends.
  Future<void> refresh() => _refresh(afterBuild: true);

  /// [refresh]; without [afterBuild] only the list being read lands (a host
  /// event that changed no conversation).
  Future<void> _refresh({required bool afterBuild}) async {
    final r = ref;
    final conn = r.read(readListLiveConnectionProvider);
    if (conn == null) return;
    if (state.isLoading && _buildRead != null) {
      try {
        await _buildRead;
      } catch (_) {
        // build owns the AsyncError. Background refreshes (including the
        // HostReady timer) retain the existing non-throwing refresh contract.
        return;
      }
      if (!afterBuild || !r.mounted) return;
      // Refreshes asked for meanwhile share the one read.
      return _afterBuild ??= _refreshNow().whenComplete(() => _afterBuild = null);
    }
    return _refreshNow();
  }

  Future<void> _refreshNow() async {
    final r = ref;
    final conn = r.read(readListLiveConnectionProvider);
    if (conn == null) return;
    final seq = ++_loadSeq;
    final identity = r.read(readListIdentityProvider);
    final cache = r.read(readListCacheProvider);
    final activity = cache.beginRefresh(ReadListKind.sessions, identity);
    try {
      final sessions = await _load(r, conn.client, seq, identity);
      if (r.mounted && seq == _loadSeq) {
        state = AsyncData(sessions);
        cache.finishRefresh(ReadListKind.sessions, activity);
        _appliedRefreshSeq = seq;
      }
    } catch (error, stack) {
      // A failed background refresh keeps the list it had.
      if (r.mounted && seq == _loadSeq) {
        cache.finishRefresh(ReadListKind.sessions, activity, failed: true);
        if (!state.hasValue) state = AsyncError(error, stack);
      }
    }
  }

  /// A send right after connecting can beat the lists the fallback reads. Give
  /// them a moment; a host that never answers still gets to start the chat.
  Future<void> _listsForNewChat() async {
    ProviderSubscription<WorkspacesState>? listening;
    final registry = Completer<void>();
    void check(WorkspacesState workspaces) {
      if (workspaces.status != WorkspacesStatus.loading && !registry.isCompleted) registry.complete();
    }

    try {
      check(ref.read(workspacesProvider));
      if (!registry.isCompleted) listening = ref.listen(workspacesProvider, (_, next) => check(next));
      await Future.wait([future, registry.future]).timeout(const Duration(seconds: 3));
    } catch (_) {
      // Too slow or failed: nothing to pick from, so the host picks.
    } finally {
      listening?.close();
    }
  }

  /// Creates a session in the workspace the drawer shows (else the default
  /// directory) and returns its id. [autoApprove] false keeps the host's
  /// permission preset even when 自动批准命令 is on (the companion's).
  Future<String> create({bool autoApprove = true}) async {
    final conn = ref.read(activeConnectionProvider).value;
    if (conn == null) throw StateError('not connected');
    return createForConnection(conn, autoApprove: autoApprove, isCurrent: () => true);
  }

  /// Creates for a captured connection. The caller retires its intent through
  /// [isCurrent]; waits and workspace fallback must not start a later write.
  Future<String> createForConnection(
    HostConnection conn, {
    required bool Function() isCurrent,
    bool autoApprove = true,
  }) async {
    final owner = ref;
    void checkCurrent() {
      if (!owner.mounted || !isCurrent()) throw const DshClosedException('session creation superseded');
    }

    checkCurrent();
    // Remote hosts: the working directory configured for that host, else the
    // workspace used last (as the official client does), else the remote DSH's
    // own default.
    var workspaceId = await workspaceForNewSession(ref);
    checkCurrent();
    if (workspaceId == null && _hostPicksNewChatDirectory(conn)) {
      await _listsForNewChat();
      checkCurrent();
      final sameHost = identical(ref.read(activeConnectionProvider).value?.client, conn.client);
      if (sameHost) workspaceId = _recentForNewChat(conn, ref.read(workspacesProvider), state.value)?.workspaceId;
    }
    final created = await createSessionInWorkspace(
      conn.client,
      workspaceId,
      cwd: conn.isLocal ? localWorkspaceDir : conn.workingDirectory,
      checkCurrent: checkCurrent,
    );
    checkCurrent();
    // Safe mode keeps the default preset: the agent there repairs the engine
    // with a full shell already, and every command should still be asked.
    final safeMode = ref.read(localRuntimeProvider).status.inSafeMode;
    if (autoApprove && conn.isLocal && !safeMode && ref.read(settingsProvider).autoApproveCommands) {
      try {
        await conn.client.setPermissionPreset(created.sessionId, 'danger-full-access');
      } catch (_) {
        // Keep the default preset if the command is unavailable.
      }
    }
    checkCurrent();
    unawaited(refresh());
    return created.sessionId;
  }

  /// Hides [sessionIds] now and archives them (archive(stopActivity: true))
  /// when the undo window ends, or as soon as the app leaves the screen or a
  /// newer undo notice replaces this one. Undo sends nothing.
  PendingSessionArchive scheduleArchive(Iterable<String> sessionIds) {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState == AppLifecycleState.hidden ||
        lifecycleState == AppLifecycleState.paused ||
        lifecycleState == AppLifecycleState.detached) {
      throw const DshClosedException('app is not visible');
    }
    final conn = ref.read(activeConnectionProvider).value;
    final host = ref.read(activeHostProvider);
    final idsSet = sessionIds.toSet();
    final ids = idsSet.toList();
    if (conn == null ||
        !identical(ref.read(readListLiveConnectionProvider), conn) ||
        ids.isEmpty ||
        state.isLoading ||
        ids.any((id) => _archived.contains(id) || _deleting.contains(id))) {
      throw const DshClosedException('session owner or inventory changed');
    }
    final remaining = Set<String>.of(idsSet);
    for (final row in _all) {
      if (!row.blank && !row.isSubagent) remaining.remove(row.sessionId);
      if (remaining.isEmpty) break;
    }
    if (remaining.isNotEmpty) {
      throw const DshClosedException('session owner or inventory changed');
    }
    for (final existing in _archives) {
      if (existing.ids.any(idsSet.contains)) {
        if (existing._committing) throw StateError('archive already committing');
        if (existing.ids.length == ids.length && existing.ids.every(idsSet.contains)) return existing;
      }
    }
    final generation = conn.client.mux.generation;
    final readyGeneration = conn.client.mux.lastReadyGenerationNumber;
    final pending = PendingSessionArchive(List.unmodifiable(ids));
    pending._owned = () =>
        ref.mounted &&
        identical(ref.read(activeConnectionProvider).value, conn) &&
        ref.read(activeHostProvider) == host &&
        identical(conn.client.mux.generation, generation) &&
        conn.client.mux.lastReadyGenerationNumber == readyGeneration;
    String? restoreSelection;
    int? restoreRevision;
    void restoreCurrent() {
      if (restoreSelection != null &&
          pending.owned &&
          ref.read(currentSessionProvider.notifier).selectionRevision == restoreRevision &&
          ref.read(currentSessionProvider) == null) {
        ref.read(currentSessionProvider.notifier).select(restoreSelection);
      }
    }

    pending._cancel = () {
      if (!_archives.contains(pending) || !pending.canUndo || pending._committing) return false;
      _archives.remove(pending);
      pending._closeWindow();
      restoreCurrent();
      if (!pending._done.isCompleted) pending._done.complete(null);
      _showArchiveRows();
      return true;
    };
    // A synchronous selection listener can obtain this plan after it is
    // published below. Its rejection path must already be able to release it,
    // and a newer plan it schedules must be able to send it.
    var released = false;
    pending._release = () {
      if (released) return;
      released = true;
      _archiveLeases.remove(pending);
    };
    Future<void> commit() async {
      if (!pending.owned || !_archives.contains(pending)) {
        pending.cancel();
        return;
      }
      pending._committing = true;
      pending._closeWindow();
      final archived = <String>[];
      final failed = <String>[];
      for (final id in ids) {
        if (!pending.owned) break;
        try {
          final current = await conn.client.listSessions();
          if (!pending.owned) break;
          if (!current.any((row) => row.sessionId == id && !row.blank && !row.isSubagent)) {
            failed.add(id);
            continue;
          }
          if (_archived.contains(id)) {
            archived.add(id);
            continue;
          }
          final result = await conn.client.archiveSession(id, stopActivity: true);
          archived.add(id);
          if (pending.owned) _archived = result.toSet();
        } catch (_) {
          failed.add(id);
        }
      }
      _archives.remove(pending);
      if (pending.owned) {
        if (restoreSelection != null && failed.contains(restoreSelection)) restoreCurrent();
        _showArchiveRows();
        unawaited(refresh());
      }
      if (!pending._done.isCompleted) {
        pending._done.complete(pending.owned ? ArchiveCommitResult(archived, failed) : null);
      }
    }

    pending._commitNow = () {
      if (!_archives.contains(pending) || !pending.canUndo || pending._committing) return false;
      unawaited(commit());
      return true;
    };
    // Validate the new plan before ending any valid older waiting plan. Its
    // notice is about to be replaced, so it is sent now rather than dropped.
    final intent = ++_archiveIntent;
    _archiveBatchDepth++;
    try {
      for (final previous in _archives.toList()) {
        if (previous.canUndo && previous.commitNow()) pending.replacedPrevious = true;
      }
    } finally {
      _archiveBatchDepth--;
      if (_archiveBatchDepth == 0) _showArchiveRows();
    }
    if (intent != _archiveIntent) throw StateError('archive request superseded');
    if (!pending.owned) throw const DshClosedException('session owner changed');
    _archives.add(pending);
    _archiveLeases.add(pending);
    final selected = ref.read(currentSessionProvider);
    if (ids.contains(selected)) {
      restoreSelection = selected;
      final current = ref.read(currentSessionProvider.notifier);
      // Predict only our own select. A synchronous listener may make another
      // choice before select returns; never adopt that newer revision as ours.
      restoreRevision = current.selectionRevision + 1;
      current.select(null);
    }
    if (!pending.owned || !pending.canUndo || !_archives.contains(pending)) {
      pending.cancel();
      return pending;
    }
    // Leaving the screen (Home, recents, another app on top; the process may be
    // killed from there) sends the archive at once: the notice said 已归档,
    // and the undo it offered is gone with the screen.
    final lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) pending.commitNow();
      },
    );
    unawaited(pending.windowClosed.then((_) => lifecycle.dispose()));
    pending._timer = Timer(archiveUndoWindow, () => unawaited(commit()));
    _showArchiveRows();
    return pending;
  }

  /// Reserves a live row for a confirmed destructive request. The Host remains
  /// authoritative about jobs, descendants and other writers.
  String? beginDeletion(String sessionId) {
    if (state.isLoading || !state.hasValue || _host != ref.read(activeHostProvider)) return 'inventory-changed';
    final row = _all.where((s) => s.sessionId == sessionId && !s.blank && !s.isSubagent).firstOrNull;
    if (row == null || _deleted.contains(sessionId)) return 'inventory-changed';
    if (row.running) return 'session-active';
    if (_archiveLeases.any((p) => p.ids.contains(sessionId))) return 'archive-pending';
    if (!_deleting.add(sessionId)) return 'busy';
    return null;
  }

  void endDeletion(String sessionId) => _deleting.remove(sessionId);

  /// Called only for a matching successful Host response, never optimistically.
  void confirmDeleted(String sessionId) {
    _deleted.add(sessionId);
    _deleting.remove(sessionId);
    _all = _all.where((s) => s.sessionId != sessionId).toList();
    _archived = {..._archived}..remove(sessionId);
    _titles.remove(sessionId);
    _titleFailures.remove(sessionId);
    _titleReads?.queue.removeWhere((s) => s.sessionId == sessionId);
    if (state.hasValue && !state.isLoading) state = AsyncData(_visible());
  }

  Future<void> archive(String sessionId) async {
    if (_deleting.contains(sessionId) || _deleted.contains(sessionId)) {
      throw const DshClosedException('session is being deleted');
    }
    final conn = ref.read(activeConnectionProvider).value;
    if (conn == null) throw const DshClosedException('not connected');
    await conn.client.archiveSession(sessionId, stopActivity: true);
    await refresh();
  }

  Future<void> unarchive(String sessionId) async {
    final conn = ref.read(activeConnectionProvider).value;
    if (conn == null) throw const DshClosedException('not connected');
    await conn.client.unarchiveSession(sessionId);
    await refresh();
  }

  Future<void> rename(String sessionId, String title) async {
    final conn = ref.read(activeConnectionProvider).value;
    if (conn == null) return;
    await conn.client.renameSession(sessionId, title);
    await refresh();
  }
}

final sessionsProvider = AsyncNotifierProvider<SessionsController, List<SessionSummary>>(SessionsController.new);

/// A remote host with no working directory of its own: without a workspace, a
/// new conversation would land wherever its `dsh web` happened to start.
bool _hostPicksNewChatDirectory(HostConnection? conn) => conn != null && !conn.isLocal && conn.workingDirectory == null;

Workspace? _recentForNewChat(HostConnection? conn, WorkspacesState registry, List<SessionSummary>? sessions) {
  if (!_hostPicksNewChatDirectory(conn) || !registry.ready || sessions == null) return null;
  return recentWorkspace(registry.workspaces, sessions);
}

/// Where a new conversation falls back to when the drawer selects no workspace;
/// null while the lists load, on hosts with a directory of their own, or when
/// the host has no workspace yet.
final recentWorkspaceForNewChatProvider = Provider<Workspace?>((ref) {
  final conn = ref.watch(activeConnectionProvider).value;
  // Elsewhere the chat screen must not start the lists just to learn this.
  if (!_hostPicksNewChatDirectory(conn)) return null;
  return _recentForNewChat(conn, ref.watch(workspacesProvider), ref.watch(sessionsProvider).value);
});

/// Whether a new conversation will run in the host's own default directory,
/// because the host has no workspace to fall back to.
final newChatInHostDefaultProvider = Provider<bool>((ref) {
  if (!_hostPicksNewChatDirectory(ref.watch(activeConnectionProvider).value)) return false;
  final registry = ref.watch(workspacesProvider);
  return registry.ready && registry.workspaces.isEmpty;
});

/// The title reads of one connection ([SessionsController._readTitles]).
class _TitleReads {
  _TitleReads(this.client, this.ref, this.now);

  final DshClient client;
  final DateTime Function() now;

  /// The build reads land in: a rebuild on the same connection takes them over.
  Ref ref;

  /// Rows to read next, newest first.
  final queue = ListQueue<SessionSummary>();

  /// Rows being read now.
  final running = <String>{};

  /// The connection went (or the host changed): nothing more starts, and
  /// nothing that comes back lands.
  bool retired = false;
}

/// Folder chosen for the unsent new-chat draft, scoped to the active host.
/// This is a local drawer folder, not the engine's working directory.
class PendingSessionFolderController extends Notifier<String?> {
  @override
  String? build() {
    ref.watch(activeHostProvider);
    return null;
  }

  void select(String? folderId) => state = folderId;
}

final pendingSessionFolderProvider = NotifierProvider<PendingSessionFolderController, String?>(
  PendingSessionFolderController.new,
);

/// The session shown in the chat screen; null means "new chat".
class CurrentSessionController extends Notifier<String?> {
  static const _key = 'last_session_id';
  static const _selectionKey = 'last_session_selection';

  static String _hostKey(HostRef host) => '${host.kind.name}:${host.id}';

  /// Every explicit choice counts, including selecting the already-null new chat.
  int _selectionRevision = 0;
  int get selectionRevision => _selectionRevision;

  /// Something was chosen before the last conversation was read back (新对话
  /// from a share or a launcher shortcut on a cold start): that choice stands.
  bool _touched = false;

  @override
  String? build() {
    _restore();
    return null;
  }

  /// Reopens the conversation that was open when the app was last closed.
  Future<void> _restore() async {
    final owner = ref;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!owner.mounted || _touched || state != null) return;
      final raw = prefs.getString(_selectionKey);
      final legacy = prefs.getString(_key);
      if (raw == null && legacy == null) return;

      await owner.read(activeHostProvider.notifier).ready;
      if (!owner.mounted || _touched || state != null) return;
      final host = owner.read(activeHostProvider);
      if (raw != null) {
        final saved = jsonDecode(raw);
        if (saved is! Map || saved['host'] != _hostKey(host)) return;
        final id = saved['sessionId'];
        if (id is String) state = id;
      } else {
        // Old IDs have no host binding. Keep their existing compatibility
        // only when startup actually chose the saved host; a skipped remote
        // must not turn its unbound ID into a local conversation.
        if (HostRef.decode(prefs.getString(ActiveHostController.prefsKey)) == host) state = legacy;
      }
    } catch (_) {
      // No preferences backend (tests) or unreadable store: start with a new chat.
    }
  }

  void select(String? sessionId) {
    _selectionRevision++;
    _touched = true;
    final host = ref.read(activeHostProvider);
    ref.read(pendingSessionFolderProvider.notifier).select(null);
    state = sessionId;
    unawaited(_persist(host, sessionId));
  }

  Future<void> _persist(HostRef host, String? sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // One value owns both pieces, including an explicit new-chat choice.
      // Its null ID also wins if removing a leftover legacy key fails.
      await prefs.setString(_selectionKey, jsonEncode({'host': _hostKey(host), 'sessionId': sessionId}));
      await prefs.remove(_key);
    } catch (_) {}
  }
}

final currentSessionProvider = NotifierProvider<CurrentSessionController, String?>(CurrentSessionController.new);
