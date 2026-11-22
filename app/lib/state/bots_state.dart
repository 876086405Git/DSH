// DS Bot on the active host (docs/design/dsbot.md): whether the plugin is
// there and speaks our API, the team and what its Bots are doing, the live
// feed, each chat and group chat, unread counts, and Bot notifications.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../ui/chat/secret_mask.dart';
import 'app_info.dart';
import 'connection_state.dart';
import 'hosts_state.dart';
import 'notify_state.dart';

// ── The plugin on the active host ────────────────────────────────────────────

/// Builds the API for a connection; null when the carrier cannot reach plugin
/// routes (the relay). Tests swap in a fake transport.
final dsBotApiFactoryProvider = Provider<DsBotApi? Function(HostConnection connection)>(
  (ref) =>
      (connection) => DsBotApi.of(connection.client),
);

/// The npm package the app installs.
const dsBotPackage = 'ds-bot';

enum DsBotAvailability {
  /// No host connected.
  offline,

  /// Connecting to the host, or asking DS Bot who it is.
  connecting,

  /// Reached through the relay, which does not forward plugin routes.
  relay,

  /// The host has no DS Bot (or has it turned off).
  missing,

  /// A DS Bot from before the mobile API, or one with no version in common.
  outdated,

  /// Talking to DS Bot.
  ready,

  /// DS Bot answered with something unexpected.
  failed,
}

@immutable
class DsBotStatus {
  const DsBotStatus({
    required this.availability,
    this.host = HostRef.local,
    this._hostLabel,
    this.isLocal = true,
    this.hello,
    this.team,
    this.live = const DsBotLive(),
    this.error,
    this.feedConnected = false,
  });

  final DsBotAvailability availability;
  final HostRef host;
  final String? _hostLabel;
  String get hostLabel => _hostLabel ?? appL10n.commonThisPhone;
  final bool isLocal;
  final DsBotHello? hello;

  /// Null until the first `state` answer.
  final DsBotTeam? team;
  final DsBotLive live;
  final String? error;
  final bool feedConnected;

  bool get ready => availability == DsBotAvailability.ready && team != null;

  /// Another DSH holds the team: it shows but cannot change.
  String? get readOnly => team?.readOnly ?? hello?.readOnly;

  bool supports(String capability) => hello?.supports(capability) ?? false;

  DsBotStatus copyWith({
    DsBotAvailability? availability,
    DsBotHello? hello,
    DsBotTeam? team,
    DsBotLive? live,
    String? Function()? error,
    bool? feedConnected,
  }) => DsBotStatus(
    availability: availability ?? this.availability,
    host: host,
    hostLabel: _hostLabel,
    isLocal: isLocal,
    hello: hello ?? this.hello,
    team: team ?? this.team,
    live: live ?? this.live,
    error: error == null ? this.error : error(),
    feedConnected: feedConnected ?? this.feedConnected,
  );
}

/// A short human line for a failed call; DS Bot's own (English) wording stays
/// out of the interface.
String describeDsBotError(Object error) => switch (error) {
  DshRemoteException(:final code) when code == 'bot/read-only' => appL10n.stateBotTeamBusy,
  DshRemoteException() => appL10n.stateBotOperationFailed,
  DshHttpException(:final statusCode) when statusCode == 404 => appL10n.stateBotMissing,
  DshHttpException(:final statusCode) when statusCode == 401 || statusCode == 403 => appL10n.stateHostAuthFailed,
  DshTransportException() => appL10n.commonEngineUnreachable,
  _ => appL10n.stateUnexpectedError,
};

/// Compact ranges: live notices are ordered, even while a catch-up request
/// fails. Keeping ranges avoids one retained integer per live notification.
class _NoticeSequences {
  final _ranges = <({int first, int last})>[];
  int? get maximum => _ranges.isEmpty ? null : _ranges.last.last;
  void clear() => _ranges.clear();

  bool add(int seq) {
    if (_ranges.any((range) => seq >= range.first && seq <= range.last)) return false;
    var at = 0;
    while (at < _ranges.length && _ranges[at].last < seq - 1) {
      at++;
    }
    var first = seq;
    var last = seq;
    while (at < _ranges.length && _ranges[at].first <= last + 1) {
      final range = _ranges.removeAt(at);
      if (range.first < first) first = range.first;
      if (range.last > last) last = range.last;
    }
    _ranges.insert(at, (first: first, last: last));
    return true;
  }
}

/// DS Bot on the active host. Lives as long as something watches it: the Bot
/// pages, and the shell's [BotAlertsHost] so notifications keep coming.
class DsBotController extends Notifier<DsBotStatus> {
  DsBotApi? _api;
  DsBotFeed? _feed;
  StreamSubscription<DsBotFeedEvent>? _feedSub;
  int _generation = 0;
  Timer? _stateTimer;
  int? _stateBusyGeneration;
  bool _stateAgain = false;
  String? _noticeBoot;
  String? _observedFeedBoot;
  bool _noticeSyncing = false;
  int _noticeSync = 0;
  final _noticed = _NoticeSequences();

  final _events = StreamController<DsBotFeedEvent>.broadcast();
  final _notices = StreamController<({DsBotNotice notice, bool caughtUp})>.broadcast();

  /// The API of the current host; null unless the host can be reached.
  DsBotApi? get api => _api;

  /// Latest non-empty boot observed on this API's feed, retained across page
  /// lifetimes until connection teardown. A missing boot does not erase proof
  /// that the server restarted after the current HTTP hello.
  String? get observedFeedBoot => _observedFeedBoot;

  /// Feed events, for the open chats.
  Stream<DsBotFeedEvent> get events => _events.stream;

  /// New notices, live or read back after a reconnect (`caughtUp`).
  Stream<({DsBotNotice notice, bool caughtUp})> get notices => _notices.stream;

  @override
  DsBotStatus build() {
    final connAsync = ref.watch(activeConnectionProvider);
    final host = ref.watch(activeHostProvider);
    ref.onDispose(_teardown);
    final conn = connAsync.value;
    if (conn == null) {
      return DsBotStatus(
        availability: connAsync.isLoading ? DsBotAvailability.connecting : DsBotAvailability.offline,
        host: host,
      );
    }
    final base = DsBotStatus(
      availability: DsBotAvailability.connecting,
      host: host,
      hostLabel: conn.isLocal ? null : conn.label,
      isLocal: conn.isLocal,
    );
    final api = ref.read(dsBotApiFactoryProvider)(conn);
    if (api == null) return base.copyWith(availability: DsBotAvailability.relay);
    _api = api;
    final generation = ++_generation;
    scheduleMicrotask(() => _open(generation));
    return base;
  }

  void _teardown() {
    _generation++;
    _stateTimer?.cancel();
    _stateTimer = null;
    _stateBusyGeneration = null;
    _stateAgain = false;
    _noticeBoot = null;
    _observedFeedBoot = null;
    _noticeSyncing = false;
    _noticeSync++;
    _noticed.clear();
    final sub = _feedSub;
    final feed = _feed;
    final api = _api;
    _feedSub = null;
    _feed = null;
    _api = null;
    unawaited(() async {
      await sub?.cancel();
      await feed?.close();
      await api?.close();
    }());
  }

  bool _current(int generation) => ref.mounted && generation == _generation;

  Future<void> _open(int generation) async {
    final api = _api;
    if (api == null || !_current(generation)) return;
    final DsBotHello hello;
    try {
      hello = await api.hello(version: AppInfo.version);
    } catch (error) {
      if (!_current(generation)) return;
      final availability = switch (error) {
        DshHttpException(:final statusCode) when statusCode == 404 => DsBotAvailability.missing,
        DshRemoteException(:final code) when code == 'bot/not-found' || code == 'bot/read-only' =>
          DsBotAvailability.outdated,
        // The relay's allow-list does not carry `dsBot/*` yet.
        DshRemoteException(:final code) when code == 'METHOD_NOT_ALLOWED' => DsBotAvailability.relay,
        _ => DsBotAvailability.failed,
      };
      state = state.copyWith(availability: availability, error: () => describeDsBotError(error));
      return;
    }
    if (!_current(generation)) return;
    if (!hello.compatible) {
      state = state.copyWith(availability: DsBotAvailability.outdated, hello: hello);
      return;
    }
    state = state.copyWith(hello: hello, error: () => null);
    await _loadState(generation, full: true);
    if (!_current(generation)) return;
    final feed = _feed = api.feed();
    _feedSub = feed.events.listen(_onFeed);
    feed.start();
  }

  Future<void> _loadState(int generation, {bool full = false}) async {
    final api = _api;
    if (api == null) return;
    if (_stateBusyGeneration == generation) {
      _stateAgain = true;
      return;
    }
    _stateBusyGeneration = generation;
    try {
      final team = state.team;
      final answer = await api.state(since: full ? null : team?.revision, modelsKey: full ? null : team?.modelsKey);
      if (!_current(generation)) return;
      state = state.copyWith(
        availability: DsBotAvailability.ready,
        team: answer.team,
        live: answer.live,
        error: () => null,
      );
    } catch (error) {
      if (!_current(generation)) return;
      // A team already on screen stays; the next feed event tries again.
      if (state.team == null) {
        state = state.copyWith(availability: DsBotAvailability.failed, error: () => describeDsBotError(error));
      }
    } finally {
      // An old host must not release the new host's in-flight read.
      if (_stateBusyGeneration == generation) {
        _stateBusyGeneration = null;
        if (_stateAgain && _current(generation)) {
          _stateAgain = false;
          unawaited(_loadState(generation));
        }
      }
    }
  }

  /// Reads the team again soon; bursts of feed events make one read.
  void _scheduleState({Duration delay = const Duration(milliseconds: 150)}) {
    final generation = _generation;
    _stateTimer ??= Timer(delay, () {
      _stateTimer = null;
      if (_current(generation)) unawaited(_loadState(generation));
    });
  }

  void _onFeed(DsBotFeedEvent event) {
    final generation = _generation;
    switch (event) {
      case DsBotFeedHello():
        final boot = event.boot;
        final knownBoot = state.hello?.boot;
        if (boot != null && boot.isNotEmpty && knownBoot != null && knownBoot.isNotEmpty && boot != knownBoot) {
          // A restarted plugin can change API compatibility and capabilities.
          // Re-open the connection so pages and pending actions lose the old API.
          retry();
          return;
        }
        state = state.copyWith(feedConnected: true);
        if (event.boot case final boot? when boot.isNotEmpty) _observedFeedBoot = boot;
        if (_noticeBoot != event.boot) _noticed.clear();
        _noticeBoot = event.boot;
        _noticeSyncing = event.boot != null;
        final sync = ++_noticeSync;
        unawaited(_catchUp(generation, event, sync));
        _scheduleState(delay: Duration.zero);
      case DsBotFeedRevision() || DsBotFeedLive():
        _scheduleState();
      case DsBotFeedNotice(:final notice):
        _acceptNotice(notice, caughtUp: false);
      case DsBotFeedLost(:final error):
        if (error is DshHttpException && error.statusCode == 404) {
          // A missing mobile feed is a capability failure, not a transient drop.
          // Stop its automatic retry loop; the visible Retry action rechecks it.
          unawaited(_feed?.close());
          _feed = null;
          _teardown();
          state = state.copyWith(availability: DsBotAvailability.outdated, feedConnected: false);
        } else {
          state = state.copyWith(feedConnected: false);
        }
      default:
        break;
    }
    if (!_events.isClosed) _events.add(event);
  }

  // Where this device stopped reading notices, per host: the host's boot and
  // the last seq seen.
  String get _cursorKey => 'dsbot_cursor_${state.host.encode()}';
  final _cursors = <String, ({String boot, int seq})>{};

  Future<({String boot, int seq})?> _readCursor(String key) async {
    if (_cursors[key] case final cached?) return cached;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      final map = raw == null ? null : jsonDecode(raw);
      if (map is Map && map['boot'] is String && map['seq'] is int) {
        return _cursors[key] = (boot: map['boot'] as String, seq: map['seq'] as int);
      }
    } catch (_) {
      // No preferences backend (tests): start from the host's current seq.
    }
    return null;
  }

  Future<void> _writeCursor(String key, String boot, int seq) async {
    // A live notice may have moved it on while a catch-up was in flight.
    final cursor = _cursors[key];
    if (cursor != null && cursor.boot == boot && cursor.seq > seq) return;
    _cursors[key] = (boot: boot, seq: seq);
    try {
      final prefs = await SharedPreferences.getInstance();
      // A newer cursor may have won while the preferences backend opened.
      final latest = _cursors[key];
      if (latest?.boot != boot || latest?.seq != seq) return;
      await prefs.setString(key, jsonEncode({'boot': boot, 'seq': seq}));
    } catch (_) {
      // Kept for this run only.
    }
  }

  Future<void> _advance(int seq) async {
    final key = _cursorKey;
    final cursor = _cursors[key];
    final boot = _noticeBoot;
    if (boot == null) return;
    if (cursor == null || cursor.boot != boot || seq > cursor.seq) await _writeCursor(key, boot, seq);
  }

  void _acceptNotice(DsBotNotice notice, {required bool caughtUp}) {
    final boot = _noticeBoot;
    if (boot == null || notice.seq <= 0) return;
    final cursor = _cursors[_cursorKey];
    if (cursor?.boot == boot && notice.seq <= cursor!.seq) return;
    if (!_noticed.add(notice.seq)) return;
    // New notice kinds advance the cursor but have no known UI semantics yet.
    if (const {
      DsBotNoticeKind.message,
      DsBotNoticeKind.group,
      DsBotNoticeKind.done,
      DsBotNoticeKind.question,
      DsBotNoticeKind.view,
      DsBotNoticeKind.approval,
    }.contains(notice.kind)) {
      _notices.add((notice: notice, caughtUp: caughtUp));
    }
    if (!_noticeSyncing) unawaited(_advance(notice.seq));
  }

  /// After (re)connecting, reconcile missing notices before acknowledging live
  /// notices beyond that gap. Both paths share sequence deduplication.
  Future<void> _catchUp(int generation, DsBotFeedHello hello, int sync) async {
    final key = _cursorKey;
    final boot = hello.boot;
    final api = _api;
    if (boot == null || api == null) return;
    bool current() => _current(generation) && sync == _noticeSync && boot == _noticeBoot;
    Future<void> finish(int seq) async {
      if (!current()) return;
      final seen = _noticed.maximum;
      final next = seen != null && seen > seq ? seen : seq;
      _noticeSyncing = false;
      _noticed.clear();
      await _writeCursor(key, boot, next);
    }

    final cursor = await _readCursor(key);
    if (!current()) return;
    if (cursor == null || cursor.boot != boot) {
      await finish(hello.seq ?? 0);
      return;
    }
    if ((hello.seq ?? 0) <= cursor.seq) {
      await finish(cursor.seq);
      return;
    }
    try {
      final answer = await api.notices(boot: boot, since: cursor.seq);
      if (!current() || answer.boot != boot) return;
      if (!answer.reset) {
        for (final notice in answer.notices) {
          _acceptNotice(notice, caughtUp: true);
        }
      }
      await finish(answer.seq);
    } catch (_) {
      // Keep the persisted cursor before the gap. Live notices still appear,
      // but a later hello must be able to ask for the missed range again.
    }
  }

  /// Asks DS Bot again now (「重试」, after an install).
  void retry() => ref.invalidateSelf();

  /// Reads the team again after a change made here.
  Future<void> refresh() => _loadState(_generation);

  /// The app came back or the network changed.
  void kick() => _feed?.kick();
}

final dsBotProvider = NotifierProvider<DsBotController, DsBotStatus>(DsBotController.new);

/// Every DSH Session the active host's team uses (Bots' chats in all their
/// parts, groups, members' hidden group Sessions). The sessions drawer leaves
/// them out; empty without DS Bot.
final dsBotOwnedSessionsProvider = Provider<Set<String>>(
  (ref) => ref.watch(dsBotProvider.select((s) => s.team?.sessionIds ?? const <String>{})),
);

/// Whether a generic chat alert belongs to DS Bot, which sends its own
/// (`notify_state.dart` skips these).
final dsBotSessionFilterProvider = Provider<bool Function(HostRef host, String sessionId)>((ref) {
  final status = ref.watch(dsBotProvider);
  final owned = status.team?.sessionIds ?? const <String>{};
  return (host, sessionId) => host == status.host && owned.contains(sessionId);
});

// ── Photos ───────────────────────────────────────────────────────────────────

/// A Bot's photo, decoded once per reference and connection generation.
final dsBotPhotoProvider = FutureProvider.family<Uint8List?, ({String botId, String ref})>((ref, key) async {
  final hub = ref.watch(dsBotProvider.notifier);
  final identity = ref.watch(dsBotProvider.select((s) => (s.host, s.hello?.boot, s.ready, hub.api)));
  final api = identity.$4;
  if (api == null || !identity.$3) return null;
  final photo = await api.avatar(key.botId);
  return decodeDataUrl(photo.image);
});

/// The bytes of a `data:image/...;base64,` URL.
Uint8List? decodeDataUrl(String? url) {
  if (url == null) return null;
  final comma = url.indexOf(',');
  if (!url.startsWith('data:') || comma < 0 || !url.substring(0, comma).endsWith(';base64')) return null;
  try {
    return base64Decode(url.substring(comma + 1));
  } on FormatException {
    return null;
  }
}

// ── Where the person is looking, unread, notifications ───────────────────────

/// The Bot or group chat on screen (its id), set by the chat pages.
class DsBotViewingController extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? id) {
    if (id != state) state = id;
  }

  /// Clears it only if [id] is still the one shown (a page leaving after the
  /// next one opened).
  void leave(String id) {
    if (state == id) state = null;
  }
}

final dsBotViewingProvider = NotifierProvider<DsBotViewingController, String?>(DsBotViewingController.new);

/// What the Bots home shows per conversation beyond the team: unread counts
/// and the latest notice.
@immutable
class DsBotInbox {
  const DsBotInbox({this.unread = const {}, this.latest = const {}});

  final Map<String, int> unread;
  final Map<String, DsBotNotice> latest;

  int unreadOf(String id) => unread[id] ?? 0;
  int get total => unread.values.fold(0, (a, b) => a + b);
}

/// Counts notices per conversation while it is not on screen, posts system
/// notifications while the app is in the background, and clears both when
/// the conversation opens.
class DsBotInboxController extends Notifier<DsBotInbox> {
  StreamSubscription<({DsBotNotice notice, bool caughtUp})>? _sub;

  NotifyChannel get _channel => ref.read(notifyChannelProvider);

  @override
  DsBotInbox build() {
    final hub = ref.watch(dsBotProvider.notifier);
    // A new host starts with an empty inbox: watching it rebuilds this.
    ref.watch(dsBotProvider.select((s) => s.host));
    _sub = hub.notices.listen((entry) => _onNotice(entry.notice));
    ref.onDispose(() => unawaited(_sub?.cancel()));
    ref.listen(dsBotViewingProvider, (_, id) {
      if (id != null) seen(id);
    });
    return const DsBotInbox();
  }

  void _onNotice(DsBotNotice notice) {
    final id = notice.conversationId;
    final foreground = ref.read(appForegroundProvider);
    final viewing = ref.read(dsBotViewingProvider);
    final latest = {...state.latest, id: notice};
    if (foreground && viewing == id) {
      state = DsBotInbox(unread: state.unread, latest: latest);
      return;
    }
    state = DsBotInbox(unread: {...state.unread, id: state.unreadOf(id) + 1}, latest: latest);
    // In the app, the unread dot says it; outside, a notification.
    if (foreground) return;
    final prefs = ref.read(notifyPrefsProvider);
    if (!prefs.allows(_alertKind(notice.kind))) return;
    unawaited(_channel.show(dsBotPost(ref.read(dsBotProvider).host, notice)));
  }

  /// The person opened [id]: no unread, no notification.
  void seen(String id) {
    if (state.unread.containsKey(id)) {
      state = DsBotInbox(unread: {...state.unread}..remove(id), latest: state.latest);
    }
    unawaited(_channel.cancelGroup(dsBotNotifyGroup(ref.read(dsBotProvider).host, id)));
  }
}

final dsBotInboxProvider = NotifierProvider<DsBotInboxController, DsBotInbox>(DsBotInboxController.new);

/// Which notification switch a notice follows.
AlertKind _alertKind(String kind) => switch (kind) {
  DsBotNoticeKind.question || DsBotNoticeKind.view => AlertKind.question,
  DsBotNoticeKind.approval => AlertKind.approval,
  _ => AlertKind.done,
};

/// Taps on these open the Bot or group chat (`openDsBotTap`).
const dsBotTapBot = 'dsbot-bot';
const dsBotTapRoom = 'dsbot-room';

String dsBotNotifyGroup(HostRef host, String conversationId) => notifyGroup(host, 'dsbot:$conversationId');

/// The system notification for [notice]: one per Bot or group, the newest
/// replacing the older.
NotifyPost dsBotPost(HostRef host, DsBotNotice notice) {
  final room = notice.roomId != null;
  final name = notice.name.isEmpty ? 'Bot' : notice.name;
  final text = switch (notice.kind) {
    DsBotNoticeKind.done => appL10n.stateBotFinished(name),
    DsBotNoticeKind.question || DsBotNoticeKind.view => appL10n.stateBotQuestion(name, notice.text),
    DsBotNoticeKind.approval => appL10n.stateBotApproval(name, notice.text),
    _ when room => appL10n.stateActionReason(name, notice.text),
    _ => notice.text,
  };
  return NotifyPost(
    group: dsBotNotifyGroup(host, notice.conversationId),
    key: 'dsbot',
    attention: DsBotNoticeKind.attention(notice.kind),
    title: maskSecrets(room ? (notice.title ?? appL10n.stateGroupChat) : name, mark: '•'),
    text: maskSecrets(text, mark: '•'),
    publicText: appL10n.stateBotNewMessage,
    sessionId: notice.conversationId,
    host: host,
    kind: room ? dsBotTapRoom : dsBotTapBot,
  );
}

// ── A Bot's own chat ─────────────────────────────────────────────────────────

/// A message sent from here that the chat does not show yet.
@immutable
class DsBotPending {
  const DsBotPending(this.text, this.at, {this.failed = false});
  final String text;
  final DateTime at;
  final bool failed;
}

@immutable
class BotChatState {
  const BotChatState({
    this.items = const [],
    this.cursor,
    this.loading = true,
    this.loadingEarlier = false,
    this.error,
    this.pending = const [],
    this.streaming,
    this.sessionId,
  });

  final List<DsBotItem> items;
  final Object? cursor;
  final bool loading;
  final bool loadingEarlier;
  final String? error;
  final List<DsBotPending> pending;

  /// The reply being written, as it comes.
  final String? streaming;
  final String? sessionId;

  bool get hasEarlier => cursor != null;

  BotChatState copyWith({
    List<DsBotItem>? items,
    Object? Function()? cursor,
    bool? loading,
    bool? loadingEarlier,
    String? Function()? error,
    List<DsBotPending>? pending,
    String? Function()? streaming,
    String? sessionId,
  }) => BotChatState(
    items: items ?? this.items,
    cursor: cursor == null ? this.cursor : cursor(),
    loading: loading ?? this.loading,
    loadingEarlier: loadingEarlier ?? this.loadingEarlier,
    error: error == null ? this.error : error(),
    pending: pending ?? this.pending,
    streaming: streaming == null ? this.streaming : streaming(),
    sessionId: sessionId ?? this.sessionId,
  );
}

/// Drops pending sends the chat now shows (the same text, from the user).
List<DsBotPending> settlePending(List<DsBotPending> pending, Iterable<DsBotItem> shown) {
  final texts = [
    for (final item in shown)
      if (item.kind == DsBotItemKind.user) item.text.trim(),
  ];
  final left = <DsBotPending>[];
  for (final entry in pending) {
    final at = texts.indexOf(entry.text.trim());
    if (at >= 0 && !entry.failed) {
      texts.removeAt(at);
    } else {
      left.add(entry);
    }
  }
  return left;
}

/// Pages from `chat`, new entries and the reply being written from the feed.
class BotChatController extends Notifier<BotChatState> {
  BotChatController(this.botId);

  final String botId;
  String? _attempt;
  List<({String sessionId, DsBotItem item})>? _liveDuringLoad;
  int _load = 0;
  int _earlier = 0;
  int _generation = 0;

  bool _current(int generation) => ref.mounted && generation == _generation;

  DsBotApi? get _api => ref.read(dsBotProvider.notifier).api;

  @override
  BotChatState build() {
    final hub = ref.watch(dsBotProvider.notifier);
    ref.watch(dsBotProvider.select((s) => (s.host, s.hello?.boot)));
    // A new part of the chat starts it over.
    ref.watch(dsBotProvider.select((s) => s.team?.bot(botId)?.sessionId));
    final generation = ++_generation;
    _attempt = null;
    _liveDuringLoad = null;
    final sub = hub.events.listen((event) {
      if (_current(generation)) _onEvent(event);
    });
    ref.onDispose(() {
      _generation++;
      unawaited(sub.cancel());
    });
    scheduleMicrotask(() {
      if (_current(generation)) unawaited(reload());
    });
    return const BotChatState();
  }

  Future<void> reload() async {
    final api = _api;
    if (api == null) return;
    final generation = _generation;
    final load = ++_load;
    final live = <({String sessionId, DsBotItem item})>[];
    _liveDuringLoad = live;
    _earlier++;
    if (state.loadingEarlier) state = state.copyWith(loadingEarlier: false);
    try {
      final page = await api.chat(botId);
      if (!_current(generation) || load != _load) return;
      // HTTP may have taken its snapshot before a newer SSE message arrived.
      // Only retain this read's live arrivals; older displayed rows remain
      // subject to the server's authoritative page (including an empty page).
      final items = [...page.items];
      for (final update in live) {
        if (update.sessionId == page.sessionId && !items.any((item) => item.sameAs(update.item))) {
          items.add(update.item);
        }
      }
      state = state.copyWith(
        items: items,
        cursor: () => page.cursor,
        loading: false,
        error: () => null,
        sessionId: page.sessionId,
        pending: settlePending(state.pending, items),
      );
    } catch (error) {
      if (!_current(generation) || load != _load) return;
      state = state.copyWith(loading: false, error: () => describeDsBotError(error));
    } finally {
      if (identical(_liveDuringLoad, live)) _liveDuringLoad = null;
    }
  }

  Future<void> loadEarlier() async {
    final api = _api;
    final cursor = state.cursor;
    if (api == null || cursor == null || state.loadingEarlier) return;
    final generation = _generation;
    final load = _load;
    final earlier = ++_earlier;
    state = state.copyWith(loadingEarlier: true);
    try {
      final page = await api.chat(botId, cursor: cursor);
      if (!_current(generation) || load != _load || earlier != _earlier) return;
      state = state.copyWith(items: [...page.items, ...state.items], cursor: () => page.cursor, loadingEarlier: false);
    } catch (error) {
      if (!_current(generation) || load != _load || earlier != _earlier) return;
      state = state.copyWith(loadingEarlier: false, error: () => describeDsBotError(error));
    }
  }

  void _onEvent(DsBotFeedEvent event) {
    switch (event) {
      case DsBotFeedLost():
        _attempt = null;
        state = state.copyWith(streaming: () => null);
      case DsBotFeedHello():
        _attempt = null;
        state = state.copyWith(streaming: () => null);
        // Entries may have been missed while the feed was away.
        if (!state.loading) unawaited(reload());
      case DsBotFeedMessage(botId: final id, :final sessionId, :final item) when id == botId:
        if (state.sessionId != null && sessionId != state.sessionId) {
          unawaited(reload());
          return;
        }
        if (state.items.any((other) => other.sameAs(item))) return;
        _liveDuringLoad?.add((sessionId: sessionId, item: item));
        state = state.copyWith(
          items: [...state.items, item],
          pending: settlePending(state.pending, [item]),
          streaming: item.kind == DsBotItemKind.bot ? () => null : null,
        );
      case DsBotFeedStream(botId: final id, :final sessionId, :final attemptId, :final phase, :final text)
          when id == botId:
        final currentSession = state.sessionId ?? ref.read(dsBotProvider).team?.bot(botId)?.sessionId;
        if (currentSession != null && sessionId != currentSession) return;
        if (phase == 'start') {
          _attempt = attemptId;
          state = state.copyWith(streaming: () => '');
        } else if (phase == 'end') {
          if (_attempt == attemptId) state = state.copyWith(streaming: () => null);
        } else if (_attempt == attemptId && text != null) {
          state = state.copyWith(streaming: () => '${state.streaming ?? ''}$text');
        }
      default:
        break;
    }
  }

  /// Sends [text]; it shows at once and leaves the pending list when the
  /// chat echoes it.
  Future<bool> send(String text) async {
    final api = _api;
    final trimmed = text.trim();
    if (api == null || trimmed.isEmpty) return false;
    final generation = _generation;
    final entry = DsBotPending(trimmed, DateTime.now());
    state = state.copyWith(pending: [...state.pending, entry], error: () => null);
    try {
      await api.send(botId, trimmed);
      return true;
    } catch (error) {
      if (!_current(generation)) return false;
      state = state.copyWith(
        pending: [
          for (final p in state.pending)
            if (!identical(p, entry)) p,
        ],
        error: () => describeDsBotError(error),
      );
      return false;
    }
  }

  void dismissError() => state = state.copyWith(error: () => null);
}

final botChatProvider = NotifierProvider.autoDispose.family<BotChatController, BotChatState, String>(
  BotChatController.new,
);

// ── A group chat ─────────────────────────────────────────────────────────────

@immutable
class RoomChatState {
  const RoomChatState({
    this.items = const [],
    this.cursor,
    this.loading = true,
    this.loadingEarlier = false,
    this.running = false,
    this.speaking,
    this.error,
    this.pending = const [],
  });

  final List<DsBotItem> items;
  final Object? cursor;
  final bool loading;
  final bool loadingEarlier;
  final bool running;
  final String? speaking;
  final String? error;
  final List<DsBotPending> pending;

  bool get hasEarlier => cursor != null;

  RoomChatState copyWith({
    List<DsBotItem>? items,
    Object? Function()? cursor,
    bool? loading,
    bool? loadingEarlier,
    bool? running,
    String? Function()? speaking,
    String? Function()? error,
    List<DsBotPending>? pending,
  }) => RoomChatState(
    items: items ?? this.items,
    cursor: cursor == null ? this.cursor : cursor(),
    loading: loading ?? this.loading,
    loadingEarlier: loadingEarlier ?? this.loadingEarlier,
    running: running ?? this.running,
    speaking: speaking == null ? this.speaking : speaking(),
    error: error == null ? this.error : error(),
    pending: pending ?? this.pending,
  );
}

/// Puts a fresh newest page over what is shown: everything before its first
/// item stays (earlier pages), the page replaces the rest. A page that shares
/// nothing with what is shown replaces it all.
({List<DsBotItem> items, bool joined}) mergeNewestPage(List<DsBotItem> shown, List<DsBotItem> page) {
  if (page.isEmpty) return (items: shown.isEmpty ? page : shown, joined: shown.isNotEmpty);
  final first = page.first;
  final at = shown.indexWhere((item) => item.sameAs(first));
  if (at < 0) return (items: page, joined: false);
  return (items: [...shown.take(at), ...page], joined: true);
}

/// Pages from `room-chat`; the feed's `room` event (a new line, a round
/// starting or ending) reads the newest page again.
class RoomChatController extends Notifier<RoomChatState> {
  RoomChatController(this.roomId);

  final String roomId;
  Timer? _poll;
  int _load = 0;
  int _earlier = 0;
  bool _again = false;
  int? _busyGeneration;
  int _generation = 0;

  bool _current(int generation) => ref.mounted && generation == _generation;

  /// While a round runs and the feed is away, the page is read this often.
  static const pollEvery = Duration(seconds: 3);

  DsBotApi? get _api => ref.read(dsBotProvider.notifier).api;

  @override
  RoomChatState build() {
    final hub = ref.watch(dsBotProvider.notifier);
    ref.watch(dsBotProvider.select((s) => (s.host, s.hello?.boot)));
    final generation = ++_generation;
    _again = false;
    _busyGeneration = null;
    final sub = hub.events.listen((event) {
      if (_current(generation)) _onEvent(event);
    });
    ref.onDispose(() {
      _generation++;
      _poll?.cancel();
      _poll = null;
      unawaited(sub.cancel());
    });
    scheduleMicrotask(() {
      if (_current(generation)) unawaited(refresh());
    });
    return const RoomChatState();
  }

  void _onEvent(DsBotFeedEvent event) {
    switch (event) {
      case DsBotFeedLost():
        // A connected feed may have outlived the one-shot fallback timer.
        // Repeated failed reconnects must not postpone an existing poll.
        if (state.running && _poll?.isActive != true) _armPoll(true);
      case DsBotFeedRoom(roomId: final id) when id == roomId:
        unawaited(refresh());
      case DsBotFeedHello():
        unawaited(refresh());
      default:
        break;
    }
  }

  /// Reads the newest page and merges it.
  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    final generation = _generation;
    if (_busyGeneration == generation) {
      _again = true;
      return;
    }
    _busyGeneration = generation;
    final load = ++_load;
    _earlier++;
    if (state.loadingEarlier) state = state.copyWith(loadingEarlier: false);
    try {
      final page = await api.roomChat(roomId);
      if (!_current(generation) || load != _load) return;
      final merged = mergeNewestPage(state.items, page.items);
      state = state.copyWith(
        items: merged.items,
        cursor: merged.joined && state.items.isNotEmpty ? null : () => page.cursor,
        loading: false,
        running: page.running,
        speaking: () => page.speaking,
        error: () => null,
        pending: settlePending(state.pending, page.items),
      );
      _armPoll(page.running);
    } catch (error) {
      if (!_current(generation) || load != _load) return;
      state = state.copyWith(loading: false, error: () => describeDsBotError(error));
      _armPoll(state.running);
    } finally {
      if (_busyGeneration == generation) {
        _busyGeneration = null;
        if (_again && _current(generation)) {
          _again = false;
          unawaited(refresh());
        }
      }
    }
  }

  void _armPoll(bool running) {
    _poll?.cancel();
    _poll = null;
    if (!running) return;
    final generation = _generation;
    _poll = Timer(pollEvery, () {
      if (_current(generation) && !ref.read(dsBotProvider).feedConnected) unawaited(refresh());
    });
  }

  Future<void> loadEarlier() async {
    final api = _api;
    final cursor = state.cursor;
    if (api == null || cursor == null || state.loadingEarlier) return;
    final generation = _generation;
    final load = _load;
    final earlier = ++_earlier;
    state = state.copyWith(loadingEarlier: true);
    try {
      final page = await api.roomChat(roomId, cursor: cursor);
      if (!_current(generation) || load != _load || earlier != _earlier) return;
      state = state.copyWith(items: [...page.items, ...state.items], cursor: () => page.cursor, loadingEarlier: false);
    } catch (error) {
      if (!_current(generation) || load != _load || earlier != _earlier) return;
      state = state.copyWith(loadingEarlier: false, error: () => describeDsBotError(error));
    }
  }

  Future<bool> send(String text) async {
    final api = _api;
    final trimmed = text.trim();
    if (api == null || trimmed.isEmpty) return false;
    final generation = _generation;
    final entry = DsBotPending(trimmed, DateTime.now());
    state = state.copyWith(pending: [...state.pending, entry], error: () => null);
    try {
      await api.send(roomId, trimmed);
      return true;
    } catch (error) {
      if (!_current(generation)) return false;
      state = state.copyWith(
        pending: [
          for (final p in state.pending)
            if (!identical(p, entry)) p,
        ],
        error: () => describeDsBotError(error),
      );
      return false;
    }
  }

  void dismissError() => state = state.copyWith(error: () => null);
}

final roomChatProvider = NotifierProvider.autoDispose.family<RoomChatController, RoomChatState, String>(
  RoomChatController.new,
);

// ── Details ──────────────────────────────────────────────────────────────────

/// A Bot's or a group's memory; `null` botId means the group [roomId].
final dsBotMemoryProvider = FutureProvider.autoDispose.family<DsBotMemoryView, ({String? botId, String? roomId})>((
  ref,
  key,
) async {
  final hub = ref.watch(dsBotProvider.notifier);
  final identity = ref.watch(dsBotProvider.select((s) => (s.host, s.hello?.boot, s.ready, hub.api)));
  final api = identity.$4;
  if (api == null || !identity.$3) throw const DshTransportException('not connected');
  return api.memory(botId: key.botId, roomId: key.roomId);
});

/// A Bot's token counts (needs `usage-summary`).
final dsBotUsageProvider = FutureProvider.autoDispose.family<DsBotUsageSummary?, String>((ref, botId) async {
  final status = ref.watch(dsBotProvider);
  final api = ref.read(dsBotProvider.notifier).api;
  if (api == null || !status.supports('usage-summary')) return null;
  // Mobile usage-summary groups the last 24 / 168 / 720 hourly buckets.
  // The host's time zone defines those buckets; this is not calendar-today.
  return api.usageSummary(botId);
});
