// The glue between the app's state and the pet's mood reducer (pet_mood.dart):
// what runs on every connected host, what waits on the person, the conversation
// on screen, turn-end and request alerts, the last touch — reduced into
// [PetState]s for the chat page's pet layer and the out-of-app overlay. Nothing
// here calls a model or the network beyond the host events the app already
// holds.

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notify/chat_alerts.dart';
import '../performance/performance_state.dart';
import '../state/chat_state.dart';
import '../state/connection_state.dart';
import '../state/hosts_state.dart';
import '../state/notify_state.dart' show FlagController, appForegroundProvider, chatOnScreenProvider;
import '../state/run_pulse.dart';
import '../state/session_attention_state.dart';
import '../ui/chat/run_info.dart';
import 'overlay_channel.dart' show petOverlayChannelProvider;
import 'pet_mood.dart';
import 'pet_overlay_actions.dart';
import 'pet_library.dart';
import 'pet_pack.dart';
import 'pet_prefs.dart';
import 'pet_sheets.dart';
import 'pet_state.dart';

/// The pet's clock (tests drive it by hand).
final petClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Where packs load from (tests swap in a file bundle).
final petAssetBundleProvider = Provider<AssetBundle>((ref) => rootBundle);

/// One pack, loaded once per id: a brought one from its folder, a built-in
/// one from the assets.
final petPackProvider = FutureProvider.family<PetPack, String>(
  (ref, id) =>
      isUserPet(id) ? ref.watch(petLibraryProvider).load(id) : PetPack.load(id, ref.watch(petAssetBundleProvider)),
);

/// The brought pets, oldest first, for the picker.
class UserPetsController extends AsyncNotifier<List<PetPack>> {
  /// Listings asked for, and the newest that has come back: one that comes
  /// back late (the first, slow, after an import's) never overwrites a newer.
  int _asked = 0;
  int _landed = 0;
  List<PetPack> _latest = const [];

  @override
  Future<List<PetPack>> build() {
    ref.watch(petLibraryProvider);
    return _list();
  }

  Future<List<PetPack>> _list() async {
    final ticket = ++_asked;
    final found = await ref.read(petLibraryProvider).list();
    // A pet that failed to read while it was away (an interrupted replacement,
    // put right by this listing) is read again.
    for (final pack in found) {
      final read = petPackProvider(pack.id);
      if (ref.exists(read) && ref.read(read).hasError) ref.invalidate(read);
    }
    if (ticket < _landed) return _latest;
    _landed = ticket;
    return _latest = found;
  }

  /// Lists again; when that fails, [fallback] says what changed.
  Future<void> _relist(List<PetPack> Function(List<PetPack> was) fallback) async {
    List<PetPack> next;
    try {
      next = await _list();
    } on Object {
      next = fallback(state.value ?? _latest);
    }
    if (ref.mounted) state = AsyncData(next);
  }

  /// A brought pet's files changed: nothing of the old ones may linger, here
  /// or in the overlay.
  void _changed(String id) {
    PetSheets.instance.forget(id);
    ref.invalidate(petPackProvider(id));
    unawaited(ref.read(petOverlayChannelProvider).reloadPack(id));
  }

  /// Checks and unpacks [zip] (pet_library.dart). Returns the pet and whether
  /// it replaced one of the same id; throws [PetImportException].
  Future<({PetPack pack, bool replaced})> import(File zip) async {
    final carrying = ref.read(petCarryingProvider.notifier);
    carrying.set(true);
    try {
      final (:id, :replaced) = await ref.read(petLibraryProvider).install(zip);
      _changed(id);
      final pack = await ref.read(petPackProvider(id).future);
      await _relist((was) => [...was.where((p) => p.id != id), pack]);
      return (pack: pack, replaced: replaced);
    } finally {
      if (ref.mounted) carrying.set(false);
    }
  }

  /// Removes a brought pet; when it was the chosen one, the default comes
  /// back. When it can't be removed it stays whole (pet_library.dart), is
  /// chosen again if it was, and the error is rethrown for the picker to say.
  /// Neither switch is the person's pick: a hidden pet stays hidden.
  Future<void> remove(String id) async {
    if (!isUserPet(id)) return;
    final prefs = ref.read(petPrefsProvider.notifier);
    final chosen = ref.read(petPrefsProvider).packId == id;
    if (chosen) await prefs.replacePack(defaultPetId);
    try {
      await ref.read(petLibraryProvider).remove(id);
    } on Object {
      if (chosen && ref.mounted && ref.read(petPrefsProvider).packId == defaultPetId) await prefs.replacePack(id);
      await _relist((was) => was);
      rethrow;
    }
    _changed(id);
    // Picked again while it was being deleted: it is gone, the default it is
    // (else no pet would draw, now or after a restart).
    if (ref.mounted && ref.read(petPrefsProvider).packId == id) await prefs.replacePack(defaultPetId);
    await _relist((was) => [...was.where((p) => p.id != id)]);
  }
}

final userPetsProvider = AsyncNotifierProvider<UserPetsController, List<PetPack>>(UserPetsController.new);

/// The chosen pack; null for none (or while it loads, or when it is broken).
final currentPetPackProvider = Provider<PetPack?>((ref) {
  final id = ref.watch(petPrefsProvider.select((p) => p.packId));
  if (id == noPetId) return null;
  return ref.watch(petPackProvider(id)).value;
});

// ── Alerts → events ──────────────────────────────────────────────────────────

/// Where `ChatAlertsController` hands every alert, for the pet.
class PetEventBus {
  final _events = StreamController<PetEvent>.broadcast(sync: true);
  final _companionSignals = StreamController<CompanionAlertDelivery>.broadcast(sync: true);

  /// Independent metadata lane; it never calls old PetEvent text handlers.
  Stream<CompanionAlertDelivery> get companionSignals => _companionSignals.stream;
  void companionSignal(CompanionAlertDelivery delivery) {
    if (!_companionSignals.isClosed && delivery.current) _companionSignals.add(delivery);
  }

  Stream<PetEvent> get events => _events.stream;

  /// One alert. [bubble]: it may raise a bubble (it went to the pet or to the
  /// system, not to the conversation on screen, not switched off). [asked]:
  /// the turn answered 问一句, its bubble shows the reply.
  void alert(ChatAlert alert, DateTime now, {bool bubble = false, bool asked = false}) {
    final kind = switch (alert.kind) {
      AlertKind.done => PetEventKind.done,
      // An engine restart is not the turn's failure: no error.
      AlertKind.failed
          when alert.key == turnKey &&
              (alert.turnEndKind == 'interrupted' ||
                  // l10n:keep legacy alert text prefix when no wire reason is available
                  (alert.turnEndKind == null && alert.text.startsWith('已中断'))) =>
        PetEventKind.stopped,
      AlertKind.failed => PetEventKind.failed,
      AlertKind.stopped => PetEventKind.stopped,
      AlertKind.approval => PetEventKind.approval,
      AlertKind.question => PetEventKind.question,
    };
    // A request shows what it asks; answered on the bubble only when all of it shows.
    final ask = switch (alert) {
      ChatAlert(kind: AlertKind.approval || AlertKind.question, :final eventId?) => PetAsk(
        eventId: eventId,
        token: alert.petToken,
        text: alert.petText ?? alert.text,
        approvable: alert.kind == AlertKind.approval && alert.petText != null,
        choices: alert.choices ?? const [],
      ),
      _ => null,
    };
    add(
      PetEvent(
        kind: kind,
        host: alert.host,
        sessionId: alert.sessionId,
        key: alert.key,
        title: alert.title == untitledSession ? null : alert.title,
        at: now,
        bubble: bubble,
        ask: ask,
        preview: asked && kind == PetEventKind.done ? alert.reply : null,
      ),
    );
  }

  void add(PetEvent event) => _events.add(event);

  void dispose() {
    unawaited(_events.close());
    unawaited(_companionSignals.close());
  }
}

final petEventBusProvider = Provider<PetEventBus>((ref) {
  final bus = PetEventBus();
  ref.onDispose(bus.dispose);
  return bus;
});

/// Hands [alert] to the pet (called by `ChatAlertsController._onAlert`).
void petHearAlert(Ref ref, ChatAlert alert, {bool bubble = false}) {
  final asked =
      alert.key == turnKey && ref.read(petAskedProvider.notifier).take(PetTarget(alert.host, alert.sessionId));
  ref.read(petEventBusProvider).alert(alert, ref.read(petClockProvider)(), bubble: bubble, asked: asked);
}

/// Conversations 问一句 sent to whose turn hasn't ended yet: that turn's end
/// bubble shows the reply's first lines (pet_overlay_actions.dart).
class PetAskedController extends Notifier<Set<PetTarget>> {
  @override
  Set<PetTarget> build() => const {};

  void add(PetTarget target) => state = {...state, target};

  /// Whether [target] was asked; it no longer is.
  bool take(PetTarget target) {
    if (!state.contains(target)) return false;
    state = {...state}..remove(target);
    return true;
  }
}

final petAskedProvider = NotifierProvider<PetAskedController, Set<PetTarget>>(PetAskedController.new);

// ── On screen ────────────────────────────────────────────────────────────────

/// The chat page's pet is drawn and visible (set by its layer).
final petLayerShownProvider = NotifierProvider<FlagController, bool>(() => FlagController(false));

/// The pet speaks for the app in front: its layer shows on the chat page,
/// the chat is the current route, and quiet mode is off. Alerts for other
/// conversations then go to its bubble instead of the glass banner.
final petOnScreenProvider = Provider<bool>(
  (ref) =>
      ref.watch(petLayerShownProvider) &&
      ref.watch(chatOnScreenProvider) &&
      ref.watch(appForegroundProvider) &&
      !ref.watch(petPrefsProvider.select((p) => p.quiet)),
);

/// How far the pet reaches above its perch (logical px), for the chat list's
/// bottom padding: the last line scrolls clear of it. 0 without a pet.
final petHeadroomProvider = NotifierProvider<PetHeadroomController, double>(PetHeadroomController.new);

class PetHeadroomController extends Notifier<double> {
  @override
  double build() => 0;

  void set(double value) {
    if ((value - state).abs() >= 0.5) state = value;
  }
}

// ── The last touch ───────────────────────────────────────────────────────────

class PetInteractionController extends Notifier<DateTime> {
  @override
  DateTime build() => ref.read(petClockProvider)();

  /// Something on the chat page (or the pet) was touched.
  void touch() {
    final now = ref.read(petClockProvider)();
    // Pointer storms: one update a second is plenty for a 60 s timer.
    if (now.difference(state) >= const Duration(seconds: 1)) state = now;
  }
}

final petInteractionProvider = NotifierProvider<PetInteractionController, DateTime>(PetInteractionController.new);

// ── What runs where ──────────────────────────────────────────────────────────

/// Running conversations and subagents of one host, from its `$events`
/// (status edges) and `session/list` (lineage).
class _HostRuns {
  _HostRuns(this.host, this.client, this.clock, this.onChange) {
    _sub = client.hostEvents.listen(_onEvent, onError: (_) {});
    if (client.mux.generation != null) unawaited(_list());
  }

  final HostRef host;
  final DshClient client;
  final DateTime Function() clock;
  final void Function() onChange;
  late final StreamSubscription<HostEvent> _sub;
  final Map<String, SessionSummary> _info = {};
  final Map<String, DateTime?> _running = {};
  bool _disposed = false;
  bool _listing = false;
  int _readyEpoch = 0;
  bool _listAgain = false;
  final _statusDuringList = <String>{};
  final _infoDuringList = <String>{};

  String _root(String id) {
    var current = id;
    for (var depth = 0; depth < 8; depth++) {
      final parent = _info[current]?.parentSessionId;
      if (!(_info[current]?.isSubagent ?? false) || parent == null || parent.isEmpty) return current;
      current = parent;
    }
    return current;
  }

  List<PetRun> get runs => [
    for (final MapEntry(:key, :value) in _running.entries)
      PetRun(
        host,
        key,
        subagent: _info[key]?.isSubagent ?? false,
        root: _root(key),
        since: value,
        title: _info[_root(key)]?.title,
      ),
  ];

  void _onEvent(HostEvent event) {
    if (_disposed) return;
    switch (event) {
      case HostReadyEvent():
        _readyEpoch++;
        if (_listing) {
          _listAgain = true;
        } else {
          unawaited(_list());
        }
      case SessionStatusEvent(:final sessionId, :final running):
        // Even an idempotent false edge is newer than an in-flight list.
        if (_listing) _statusDuringList.add(sessionId);
        if (running == _running.containsKey(sessionId)) return;
        if (running) {
          _running[sessionId] = clock();
        } else {
          _running.remove(sessionId);
        }
        if (!_info.containsKey(sessionId)) unawaited(_list());
        onChange();
      case SessionAddedEvent(:final summary):
        if (_listing) _infoDuringList.add(summary.sessionId);
        _info[summary.sessionId] = summary;
      case SessionRemovedEvent(:final sessionId):
        if (_listing) {
          _statusDuringList.add(sessionId);
          _infoDuringList.add(sessionId);
        }
        _info.remove(sessionId);
        if (_running.containsKey(sessionId)) {
          _running.remove(sessionId);
          onChange();
        }
      default:
        break;
    }
  }

  Future<void> _list() async {
    if (_disposed || _listing) return;
    _listing = true;
    final readyEpoch = _readyEpoch;
    _statusDuringList.clear();
    _infoDuringList.clear();
    try {
      final list = await client.listSessions();
      if (_disposed || readyEpoch != _readyEpoch) return;
      // Merge the snapshot only for fields untouched by newer stream edges.
      // Tombstones stay in the sets until this request finishes, so a removal
      // or an already-false status cannot be resurrected by its old response.
      final changedInfo = {
        for (final id in _infoDuringList)
          if (_info.containsKey(id)) id: _info[id]!,
      };
      final changedStatus = {
        for (final id in _statusDuringList)
          if (_running.containsKey(id)) id: _running[id],
      };
      _info
        ..clear()
        ..addEntries(list.where((s) => !_infoDuringList.contains(s.sessionId)).map((s) => MapEntry(s.sessionId, s)))
        ..addAll(changedInfo);
      final was = {..._running};
      _running
        ..clear()
        ..addEntries([
          for (final s in list)
            if (s.running && !_statusDuringList.contains(s.sessionId))
              MapEntry(s.sessionId, was[s.sessionId] ?? s.updatedAt),
        ])
        ..addAll(changedStatus);
      onChange();
    } catch (_) {
      // Unreachable for now: what we knew stays.
    } finally {
      _listing = false;
      _statusDuringList.clear();
      _infoDuringList.clear();
      if (_listAgain && !_disposed) {
        _listAgain = false;
        unawaited(_list());
      }
    }
  }

  void dispose() {
    _disposed = true;
    unawaited(_sub.cancel());
  }
}

/// Every running conversation and subagent on the on-device engine and the
/// active remote host.
class PetRunsController extends Notifier<List<PetRun>> {
  final Map<HostRef, _HostRuns> _hosts = {};
  bool _built = false;

  @override
  List<PetRun> build() {
    _built = false;
    ref.onDispose(() {
      for (final h in _hosts.values) {
        h.dispose();
      }
      _hosts.clear();
    });
    ref.listen(localConnectionProvider, (_, next) => _attach(HostRef.local, next.value), fireImmediately: true);
    ref.listen(activeConnectionProvider, (_, next) {
      final conn = next.value;
      final host = conn == null || conn.isLocal ? null : ref.read(activeHostProvider);
      for (final other in [..._hosts.keys]) {
        if (!other.isLocal && other != host) _attach(other, null);
      }
      if (host != null && !host.isLocal) _attach(host, conn);
    }, fireImmediately: true);
    _built = true;
    return _collect();
  }

  void _attach(HostRef host, HostConnection? connection) {
    final current = _hosts[host];
    if (current != null && identical(current.client, connection?.client)) return;
    current?.dispose();
    _hosts.remove(host);
    if (connection != null) {
      _hosts[host] = _HostRuns(host, connection.client, ref.read(petClockProvider), _changed);
    }
    _changed();
  }

  List<PetRun> _collect() => [for (final h in _hosts.values) ...h.runs];

  void _changed() {
    if (!_built) return;
    final next = _collect();
    if (next.length != state.length || !next.toSet().containsAll(state)) state = next;
  }
}

final petRunsProvider = NotifierProvider<PetRunsController, List<PetRun>>(PetRunsController.new);

// ── The conversation on screen ───────────────────────────────────────────────

/// [ActivityKind] → what the pet makes of it.
PetActivity petActivityOf(ActivityKind? kind) => switch (kind) {
  null => PetActivity.none,
  ActivityKind.tool || ActivityKind.writing => PetActivity.working,
  ActivityKind.approval || ActivityKind.question => PetActivity.waiting,
  ActivityKind.stopping => PetActivity.stopping,
  ActivityKind.waiting ||
  ActivityKind.thinking ||
  ActivityKind.retry ||
  ActivityKind.compaction => PetActivity.thinking,
};

/// Whether a conversation is compacting its context (its run pulse says).
class PetCompactingController extends Notifier<bool> {
  PetCompactingController(this.sessionId);

  final String sessionId;

  @override
  bool build() {
    final pulse = ref.watch(runPulseProvider(sessionId));
    void listener() {
      final compacting = pulse.compactingSince != null;
      if (compacting != state) state = compacting;
    }

    pulse.addListener(listener);
    ref.onDispose(() => pulse.removeListener(listener));
    return pulse.compactingSince != null;
  }
}

final petCompactingProvider = NotifierProvider.autoDispose.family<PetCompactingController, bool, String>(
  PetCompactingController.new,
);

/// The conversation the native chat page shows, and what it is doing. The
/// chat page's pet stage reports it ([PetFocusController.report]); null when
/// no chat page is up (网页模式, before the first frame). Read from the page,
/// not from `chatProvider`, so nothing here opens a conversation's stream.
class PetFocusController extends Notifier<PetFocus?> {
  @override
  PetFocus? build() => null;

  void report(PetFocus? focus) {
    if (!ref.mounted) return;
    if (focus != state) state = focus;
  }
}

final petFocusProvider = NotifierProvider<PetFocusController, PetFocus?>(PetFocusController.new);

/// What the conversation [s] is doing, for the pet.
PetFocus petFocusOf(HostRef host, String sessionId, ChatState s, {bool compacting = false}) {
  final approval = s.openApproval;
  final question = approval == null ? s.questions.firstOrNull : null;
  return PetFocus(
    host: host,
    sessionId: sessionId,
    title: s.title,
    activity: petActivityOf(runActivityOf(s)?.kind),
    compacting: compacting,
    waitingKey: approval?.eventId ?? question?.eventId,
    waitingQuestion: question != null,
  );
}

/// What waits on the person: the active host's pending requests (by their
/// top-level conversation) and the open card of the conversation on screen.
final petPendingProvider = Provider<List<PetPending>>((ref) {
  final host = ref.watch(activeHostProvider);
  final pending = ref.watch(pendingInteractionsProvider);
  final focus = ref.watch(petFocusProvider);
  final own = focus?.waitingKey;
  return [
    if (focus != null && own != null)
      PetPending(host: focus.host, sessionId: focus.sessionId, key: own, question: focus.waitingQuestion),
    for (final MapEntry(:key, :value) in pending.entries)
      if (own == null || focus == null || key != focus.sessionId || host != focus.host)
        PetPending(host: host, sessionId: key, key: value.name, question: value != PendingKind.approval),
  ];
});

/// A pet pack is being unpacked: the pet carries it in (docs/design/pets.md §4.2).
final petCarryingProvider = NotifierProvider<FlagController, bool>(() => FlagController(false));

/// All level signals.
final petSignalsProvider = Provider<PetSignals>((ref) {
  final focus = ref.watch(petFocusProvider);
  return PetSignals(
    focus: focus,
    viewed: focus != null && ref.watch(appForegroundProvider) && ref.watch(chatOnScreenProvider),
    runs: ref.watch(petRunsProvider),
    pending: ref.watch(petPendingProvider),
    lastInteraction: ref.watch(petInteractionProvider),
    carrying: ref.watch(petCarryingProvider),
    quiet: ref.watch(petPrefsProvider.select((p) => p.quiet)),
  );
});

final petTimingsProvider = Provider<PetTimings>((ref) => PetTimings.of(ref.watch(currentPetPackProvider)));

// ── The mood ─────────────────────────────────────────────────────────────────

/// Runs [reducePetMood] for one [PetScope] on every signal, event and timer.
class PetMoodController extends Notifier<PetMood> {
  PetMoodController(this.scope);

  final PetScope scope;
  Timer? _timer;
  final List<PetEvent> _events = [];
  bool _running = false;

  DateTime get _now => ref.read(petClockProvider)();

  @override
  PetMood build() {
    final sub = ref.watch(petEventBusProvider).events.listen((e) {
      _events.add(e);
      _reduce();
    });
    ref.listen(petSignalsProvider, (_, _) => _reduce());
    ref.listen(petTimingsProvider, (_, _) => _reduce());
    ref.onDispose(() {
      _timer?.cancel();
      unawaited(sub.cancel());
    });
    final now = _now;
    final first = reducePetMood(
      PetMood.initial(now),
      ref.read(petSignalsProvider),
      now,
      timings: ref.read(petTimingsProvider),
      scope: scope,
    );
    _arm(first.next);
    return first;
  }

  void _reduce() {
    if (_running) return;
    _running = true;
    try {
      final events = [..._events];
      _events.clear();
      final next = reducePetMood(
        state,
        ref.read(petSignalsProvider),
        _now,
        events: events,
        timings: ref.read(petTimingsProvider),
        scope: scope,
      );
      state = next;
      _arm(next.next);
    } finally {
      _running = false;
    }
  }

  void _arm(DateTime? at) {
    _timer?.cancel();
    _timer = null;
    if (at == null) return;
    var wait = at.difference(_now);
    if (wait.isNegative) wait = Duration.zero;
    _timer = Timer(wait + const Duration(milliseconds: 1), _reduce);
  }

  /// Re-reads the signals now (tests move the clock by hand).
  void refresh() => _reduce();

  /// The bubble was tapped or swiped away: it goes now.
  void dismissBubble(String id) {
    if (state.bubble?.id == id) state = state.copyWith(clearBubble: true);
  }
}

final petMoodProvider = NotifierProvider.family<PetMoodController, PetMood, PetScope>(PetMoodController.new);

/// What the pet shows in [scope]; bubbles and the target are global.
final petScopedStateProvider = Provider.family<PetState, PetScope>((ref, scope) {
  final global = ref.watch(petMoodProvider(PetScope.global));
  final mood = scope == PetScope.global ? global : ref.watch(petMoodProvider(scope));
  final signals = ref.watch(petSignalsProvider);
  final prefs = ref.watch(petPrefsProvider);
  final activeHost = ref.watch(activeHostProvider);
  return PetState(
    state: mood.shown,
    tier: mood.tier,
    bubble: prefs.quiet ? null : global.bubble,
    target: petTarget(global, signals),
    active: petActive(global, signals),
    foreground: ref.watch(appForegroundProvider),
    packId: prefs.packId,
    size: prefs.size,
    bodyHeight: prefs.bodyHeight,
    quiet: prefs.quiet,
    reduceMotion: ref.watch(performanceDefaultsProvider.select((p) => p.reduceMotion)),
    canStop: signals.runs.any((r) => PetTarget(r.host, r.root) == petTarget(global, signals) && r.host == activeHost),
    hosts: ref.watch(petHostChoicesProvider),
  );
});

/// The global state: the overlay's.
final petStateProvider = Provider<PetState>((ref) => ref.watch(petScopedStateProvider(PetScope.global)));

/// The pet is drawn on the chat page: the empty state's still whale tail
/// steps aside — one mascot a screen. Hidden, 不显示 or 网页模式: the whale
/// is back.
final petTakesWhaleProvider = Provider<bool>((ref) => ref.watch(petLayerShownProvider));
