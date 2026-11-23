// The one owner of her invitations for this installation (Pro C452 §2). It
// outlives pages, hosts, modes and stage reloads: the room attaches to it, it
// does not make its own. It restores and writes the ledger, keeps the two
// one-shot wakeups, and hands the controller's effects to the attached room.
// What may be offered, and when, stays the controller's (companion_initiative.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:math';

import 'package:dsh_client/companion.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'companion_initiative.dart';
import 'companion_elapsed_clock.dart';

const companionInitiativeKey = 'companion_initiative_v1';
const _enabledKey = 'companion_initiative_enabled';
const _paceKey = 'companion_initiative_pace';

/// Both clocks for the controller: the wall clock for its day-long quotas, a
/// monotonic one for quiet and display time. Tests drive their own.
final companionInitiativeClockProvider = Provider<CompanionInitiativeClock Function()>((ref) {
  final mono = CompanionElapsedClock();
  return CompanionClockSampler(elapsedMilliseconds: mono.readMilliseconds).read;
});

final companionInitiativeProvider = Provider<CompanionInitiative>((ref) {
  final owner = CompanionInitiative(ref.watch(companionInitiativeClockProvider));
  ref.onDispose(owner.dispose);
  return owner;
});

/// Whether she may invite at all. Null until read: an unread switch permits nothing.
class CompanionInitiativeEnabled extends Notifier<bool?> {
  @override
  bool? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (ref.mounted && state == null) state = prefs.getBool(_enabledKey) ?? true;
    } on Object {
      // Stays null: no invitations from a setting nobody could read.
    }
  }

  Future<void> set(bool on) async {
    state = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, on);
  }
}

final companionInitiativeEnabledProvider = NotifierProvider<CompanionInitiativeEnabled, bool?>(
  CompanionInitiativeEnabled.new,
);

/// How often she speaks up when she may (「她多主动」). Unread or unknown is
/// the original pace: two a day, six hours apart.
class CompanionInitiativePaceSetting extends Notifier<CompanionInitiativePace> {
  @override
  CompanionInitiativePace build() {
    unawaited(_load());
    return CompanionInitiativePace.rare;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = CompanionInitiativePace.byName(prefs.getString(_paceKey));
      if (ref.mounted && saved != null) state = saved;
    } on Object {
      // The original pace, then.
    }
  }

  Future<void> set(CompanionInitiativePace pace) async {
    state = pace;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_paceKey, pace.name);
  }
}

final companionInitiativePaceProvider = NotifierProvider<CompanionInitiativePaceSetting, CompanionInitiativePace>(
  CompanionInitiativePaceSetting.new,
);

/// The room the owner shows things in. Every call is synchronous: a ticket is
/// mounted, or dropped, inside the event that produced it (C452 §6).
abstract interface class CompanionInitiativeRoom {
  /// Whether [ticket] can be shown here right now, by this room.
  bool canPresent(CompanionInitiativeTicket ticket);

  void show(CompanionInitiativeDisplay display);

  void hide(String ticketId);

  /// The shown ticket now ends at [expiresAtMono], or is held (null).
  void retime(String ticketId, int? expiresAtMono);

  /// The person said yes to the invitation [intent] names. Not a rest yet:
  /// the room checks it is still its own and goes through its usual entry.
  void rest(CompanionInitiativeEffect intent);
}

class _SignalRequest {
  _SignalRequest(
    this.room,
    this.candidate,
    this.isCurrent,
    this.present,
    this.hide,
    this.followupId,
    this.prepare,
    this.cancelPrepare,
    this.deliver,
    this.retainDelivery,
    this.noticeEventId,
    this.noticePersonId,
    this.settled,
  );
  final CompanionInitiativeRoom room;
  final CompanionInitiativeSignal candidate;
  final bool Function() isCurrent;
  final bool Function(CompanionInitiativeDisplay) present;
  final void Function(String) hide;
  final String? followupId;
  final Future<bool> Function()? prepare;
  final void Function()? cancelPrepare;
  final Future<bool> Function(CompanionInitiativeDisplay)? deliver;
  final void Function(Future<void>)? retainDelivery;
  final String? noticeEventId, noticePersonId;
  final void Function(String outcome)? settled;
  bool preparing = false;
  bool prepared = false;
}

class _QueuedInitiative {
  const _QueuedInitiative(this.event, this.room, this.revision);
  final CompanionInitiativeEvent event;
  final CompanionInitiativeRoom? room;
  final int revision;
}

/// One installation owner serializes observations, presentation and persistence.
/// A displayed message is charged even when its synchronous callback changes room.
class CompanionInitiative {
  CompanionInitiative(this._readClock);
  final CompanionInitiativeClock Function() _readClock;
  bool _clockUnavailable = false;
  CompanionInitiativeClock _now() {
    if (!_clockUnavailable) {
      try {
        final stamp = _readClock();
        if (stamp.monoMs >= 0) return stamp;
      } on Object {
        // A failed native read closes this owner, including pending displays.
      }
      _clockUnavailable = true;
      dispose();
    }
    return const CompanionInitiativeClock(wallMs: 0, monoMs: -1);
  }

  CompanionInitiativeController? _controller;
  CompanionInitiativePace _pace = CompanionInitiativePace.rare;
  CompanionInitiativeRoom? _room;
  CompanionInitiativeView? _view;
  bool _disposed = false;
  bool _draining = false;
  bool _waitingDelivery = false;
  int _revision = 0;
  final _queue = Queue<_QueuedInitiative>();
  _SignalRequest? _signal;
  Timer? _signalExpiry;
  CompanionInitiativeRoom? _shownRoom;
  _SignalRequest? _shownSignal;
  String? _shownId;
  CompanionMemoryStore? _store;
  final _restored = Completer<void>();
  Future<void> get ready => _restored.future;
  String? get fault => _clockUnavailable
      ? 'clock-unavailable'
      : _controller == null
      ? (_restored.isCompleted ? 'not-restored' : 'restoring')
      : _controller!.fault;
  int? _quietSinceMono;
  int? _wokeForQuiet;
  Timer? _quietWake;
  int? _quietWakeAt;
  Timer? _expiry;
  String? _expiryTicket;
  String? _trackedContext;
  CompanionInitiativeRoom? _trackedRoom;

  /// The shared phone owner opens the database; this owner borrows it.
  /// No optional prompt can run before the existing ledger has been restored.
  Future<void> attachMemory(CompanionMemoryStore store) {
    if (_store != null) return ready;
    _store = store;
    return _restore();
  }

  Future<void> _restore() async {
    try {
      final saved = _store!.initiativeRecord();
      CompanionInitiativeRestore restored;
      if (saved != null) {
        restored = CompanionInitiativeRestore.loaded(saved);
      } else {
        final raw = (await SharedPreferences.getInstance()).get(companionInitiativeKey);
        if (raw == null) {
          restored = const CompanionInitiativeRestore.newLedger();
        } else {
          Object? value = raw;
          if (raw is String) {
            try {
              value = jsonDecode(raw);
            } on FormatException {
              // The strict reader below rejects the original malformed value.
            }
          }
          restored = CompanionInitiativeRestore.loaded(value);
        }
      }
      if (_disposed) return;
      final now = _now();
      if (_disposed) return;
      final controller = CompanionInitiativeController(now: now, restored: restored)..pace = _pace;
      if (saved == null && controller.fault == null) {
        _store!.initializeInitiative(controller.record!.toJson());
      }
      _controller = controller;
      final view = _view;
      if (_room != null && view != null) _run(CompanionInitiativeEvent.enter(view));
    } on Object {
      if (!_disposed) {
        final now = _now();
        if (!_disposed) {
          _controller = CompanionInitiativeController(
            now: now,
            restored: const CompanionInitiativeRestore.unavailable(),
          );
        }
      }
    } finally {
      if (!_restored.isCompleted) _restored.complete();
    }
  }

  /// The person's pick (「她多主动」), from the next check on: a quiet stretch
  /// already turned down under the old pace is looked at again.
  set pace(CompanionInitiativePace value) {
    if (_disposed || value == _pace) return;
    _pace = value;
    _controller?.pace = value;
    _wokeForQuiet = null;
    _run(const CompanionInitiativeEvent.check());
  }

  void enter(CompanionInitiativeRoom room, CompanionInitiativeView view) {
    if (_disposed) return;
    final old = _room;
    _revision++;
    _room = room;
    _view = view;
    if (old != null && !identical(old, room)) {
      _retireRequest();
      _enqueue(const CompanionInitiativeEvent.leave(), old);
    }
    _enqueue(CompanionInitiativeEvent.enter(view), room);
    _drain();
  }

  void leave(CompanionInitiativeRoom room) {
    if (_disposed || !identical(room, _room)) return;
    _revision++;
    _room = null;
    _view = null;
    _retireRequest();
    _enqueue(const CompanionInitiativeEvent.userActivation(), room);
    _enqueue(const CompanionInitiativeEvent.leave(), room);
    _drain();
  }

  void observe(CompanionInitiativeRoom room, CompanionInitiativeView view) {
    if (_disposed || !identical(room, _room)) return;
    _view = view;
    _revision++;
    _run(CompanionInitiativeEvent.observe(view));
  }

  void activate(CompanionInitiativeRoom room) {
    if (_disposed || !identical(room, _room)) return;
    _revision++;
    _run(const CompanionInitiativeEvent.userActivation());
  }

  bool accept(CompanionInitiativeRoom room, String ticketId, CompanionInitiativeView view) =>
      _answer(room, ticketId, view, CompanionInitiativeEvent.accept(ticketId));
  bool decline(CompanionInitiativeRoom room, String ticketId, CompanionInitiativeView view) =>
      _answer(room, ticketId, view, CompanionInitiativeEvent.decline(ticketId));
  bool _answer(CompanionInitiativeRoom room, String id, CompanionInitiativeView view, CompanionInitiativeEvent event) {
    if (_disposed || _draining || !identical(room, _room)) return false;
    _view = view;
    _revision++;
    _run(CompanionInitiativeEvent.observe(view));
    final ticket = _controller?.display?.ticket;
    if (ticket?.id != id ||
        !identical(room, _room) ||
        ticket!.kind == CompanionPromptKind.greeting ||
        (event.type == CompanionInitiativeEventType.accept && ticket.kind != CompanionPromptKind.invite)) {
      return false;
    }
    _run(event);
    return true;
  }

  /// The caller keeps the original gate expiry and provides an actual render fact.
  /// The gate must read the same [companionInitiativeClockProvider] clock's
  /// `monoMs`: Android uses BOOTTIME, not the SDK gate's default Stopwatch
  /// epoch. Never pass an absolute expiry from a different monotonic clock.
  /// Calling this before restoration never queues a delayed prompt.
  bool requestSignal(
    CompanionInitiativeRoom room,
    CompanionInitiativeView view,
    CompanionInitiativeSignal candidate, {
    required bool Function() isCurrent,
    required bool Function(CompanionInitiativeDisplay) present,
    required void Function(String) hide,
    bool nightCareEnabled = false,
    String? followupId,
    Future<bool> Function()? prepare,
    void Function()? cancelPrepare,
    Future<bool> Function(CompanionInitiativeDisplay)? deliver,
    void Function(Future<void>)? retainDelivery,
    String? noticeEventId,
    String? noticePersonId,
    void Function(String outcome)? settled,
  }) {
    if (_disposed ||
        _controller == null ||
        !identical(room, _room) ||
        candidate.contextKey != view.contextKey ||
        _signal?.candidate.id == candidate.id ||
        (followupId != null && _signal != null)) {
      return false;
    }
    final previous = _signal;
    _retireRequest();
    _view = view;
    _revision++;
    final request = _SignalRequest(
      room,
      candidate,
      isCurrent,
      present,
      hide,
      followupId,
      prepare,
      cancelPrepare,
      deliver,
      retainDelivery,
      noticeEventId,
      noticePersonId,
      settled,
    );
    _signal = request;
    if (previous != null) _enqueue(CompanionInitiativeEvent.cancelSignal(previous.candidate.id), room);
    _enqueue(CompanionInitiativeEvent.signal(candidate, nightCareEnabled: nightCareEnabled, view: view), room);
    _armSignalExpiry(request);
    _drain();
    return identical(_signal, request) && (_controller!.pendingSignal?.id == candidate.id);
  }

  void cancelSignal(String id) {
    if (_disposed) return;
    if (_signal?.candidate.id == id) _retireRequest();
    _revision++;
    _run(CompanionInitiativeEvent.cancelSignal(id));
  }

  void _retireRequest() {
    final request = _signal;
    _signal = null;
    _signalExpiry?.cancel();
    _signalExpiry = null;
    try {
      request?.cancelPrepare?.call();
    } on Object {
      // Retirement and the original gate must not depend on optional cleanup.
    }
  }

  bool _requestCurrent(_SignalRequest request) {
    bool local() =>
        !_disposed &&
        identical(_signal, request) &&
        identical(_room, request.room) &&
        _view?.contextKey == request.candidate.contextKey;
    if (!local()) return false;
    try {
      if (!request.isCurrent() || !local()) return false;
      final now = _now();
      return now.monoMs < request.candidate.expiresAtMonoMs && local();
    } on Object {
      return false;
    }
  }

  void _armSignalExpiry(_SignalRequest request) {
    final left = request.candidate.expiresAtMonoMs - _now().monoMs;
    if (_disposed) return;
    _signalExpiry = Timer(Duration(milliseconds: max(0, left)), () {
      if (!identical(_signal, request) || _disposed) return;
      if (_now().monoMs < request.candidate.expiresAtMonoMs) {
        _armSignalExpiry(request);
        return;
      }
      cancelSignal(request.candidate.id);
    });
  }

  void _enqueue(CompanionInitiativeEvent event, CompanionInitiativeRoom? room) =>
      _queue.add(_QueuedInitiative(event, room, _revision));
  void _run(CompanionInitiativeEvent event) {
    if (_disposed || _controller == null) return;
    _enqueue(event, _room);
    _drain();
  }

  void _drain() {
    final controller = _controller;
    if (_draining || _waitingDelivery || _disposed || controller == null) return;
    _draining = true;
    var transitions = 0;
    try {
      while (_queue.isNotEmpty && !_disposed && !_waitingDelivery) {
        if (++transitions > 64) {
          _queue.clear();
          final op = _QueuedInitiative(const CompanionInitiativeEvent.storageFault(), _room, _revision);
          _apply(controller, controller.handle(op.event, _now()), op);
          _queue.clear();
          break;
        }
        final op = _queue.removeFirst();
        final request = _signal;
        if (request != null && !_requestCurrent(request) && identical(_signal, request)) {
          _retireRequest();
          _apply(
            controller,
            controller.handle(CompanionInitiativeEvent.cancelSignal(request.candidate.id), _now()),
            op,
          );
        }
        if (op.event.type == CompanionInitiativeEventType.signal && !identical(op.event.signal, _signal?.candidate)) {
          continue;
        }
        _apply(controller, controller.handle(op.event, _now()), op);
        _track(op.event);
        final ticket = controller.offer;
        final prepared = _signal;
        if (_queue.isEmpty &&
            ticket != null &&
            prepared != null &&
            prepared.prepared &&
            ticket.signalId == prepared.candidate.id) {
          // Preparation may span observations. Resume the still-pending offer
          // under the current view, while reentrant render events stay queued.
          _offer(controller, ticket, _QueuedInitiative(const CompanionInitiativeEvent.check(), _room, _revision));
        }
      }
      if (_waitingDelivery) return;
      final pending = _signal;
      if (pending != null && controller.pendingSignal?.id != pending.candidate.id) _retireRequest();
      _plan(controller);
    } finally {
      _draining = false;
    }
  }

  bool _same(_QueuedInitiative op, CompanionInitiativeRoom room, _SignalRequest? request) =>
      !_disposed &&
      op.revision == _revision &&
      identical(op.room, room) &&
      identical(_room, room) &&
      (request == null || identical(_signal, request));

  void _offer(CompanionInitiativeController controller, CompanionInitiativeTicket ticket, _QueuedInitiative op) {
    if (_waitingDelivery) return;
    final room = op.room;
    final request = ticket.kind == CompanionPromptKind.signal ? _signal : null;
    bool allowed =
        room != null &&
        _same(op, room, request) &&
        (ticket.kind != CompanionPromptKind.signal || (request?.candidate.id == ticket.signalId));
    try {
      if (allowed && request != null) allowed = _requestCurrent(request);
      if (allowed) allowed = _same(op, room!, request) && room.canPresent(ticket);
      if (allowed && request != null) allowed = _requestCurrent(request);
      if (allowed) allowed = _same(op, room!, request);
    } on Object {
      allowed = false;
    }
    if (allowed && request != null && request.prepare != null && !request.prepared) {
      if (!request.preparing) {
        _prepare(controller, ticket, request);
      }
      return;
    }
    try {
      String? reservation;
      if (allowed && ticket.kind != CompanionPromptKind.greeting) {
        final now = _now();
        if (_disposed) return;
        reservation = _store!.reserveInitiative(
          kind: request?.followupId != null ? 'followup' : ticket.kind.name,
          nowMs: now.wallMs,
          maxPerDay: controller.pace.maxPerDay,
          gapMs: controller.pace.gapMs,
          followupId: request?.followupId,
          noticeEventId: request?.noticeEventId,
          noticePersonId: request?.noticePersonId,
        );
        allowed = reservation != null;
      }
      // SQLite and the last external source check may cross a window boundary.
      // Stage with a fresh clock only after both, immediately before rendering.
      if (allowed && request != null) allowed = _requestCurrent(request);
      final staged = allowed ? controller.stagePresentation(ticket.id, _now()) : null;
      if (staged == null || room == null || !_same(op, room, request)) {
        if (reservation != null) _store!.settleInitiative(reservation, outcome: 'released');
        _apply(controller, controller.handle(CompanionInitiativeEvent.dropOffer(ticket.id), _now()), op);
        return;
      }
      if (request?.deliver != null) {
        // Native notify returns an actual delivery fact. Keep the staged
        // controller state until that result; observations still update their
        // immediate current/room facts and queue their controller transitions.
        _waitingDelivery = true;
        final work = _deliver(controller, staged, op, room, request!, reservation);
        request.retainDelivery?.call(work);
        return;
      }
      var shown = false;
      var unknown = false;
      try {
        if (request != null) {
          shown = request.present(staged.display);
        } else {
          room.show(staged.display);
          shown = true;
        }
      } on Object {
        unknown = true;
      }
      if (!shown) {
        try {
          if (request != null) {
            request.hide(ticket.id);
          } else {
            room.hide(ticket.id);
          }
        } on Object {
          // Cleanup cannot prove that nothing appeared.
        }
      }
      if (shown) {
        _shownRoom = room;
        _shownSignal = request;
        _shownId = ticket.id;
      }
      if (reservation != null) {
        _store!.settleInitiative(
          reservation,
          outcome: shown
              ? 'shown'
              : unknown
              ? 'unknown'
              : 'released',
        );
      }
      request?.settled?.call(
        shown
            ? 'shown'
            : unknown
            ? 'unknown'
            : 'released',
      );
      if (!shown && !unknown) {
        _apply(controller, controller.handle(CompanionInitiativeEvent.dropOffer(ticket.id), _now()), op);
        return;
      }
      // Reentrant observations wait in the queue. True and uncertain renders
      // both consume the cached gate; SQLite keeps their distinct outcomes.
      final committed = controller.commitPresentation(staged);
      if (committed.isEmpty) {
        _hide(ticket.id);
        _apply(controller, controller.handle(const CompanionInitiativeEvent.storageFault(), _now()), op);
        return;
      }
      if (shown) _arm(ticket.id, staged.display.expiresAtMono);
      _apply(controller, committed.where((e) => e.type != CompanionInitiativeEffectType.show).toList(), op);
      if (unknown) {
        _apply(controller, controller.handle(CompanionInitiativeEvent.dropOffer(ticket.id), _now()), op);
      }
    } on Object {
      // A persisted reservation whose settlement fails remains occupied.
      // Do not show another prompt from a cache after the database failed.
      _hide(ticket.id);
      _apply(controller, controller.handle(const CompanionInitiativeEvent.storageFault(), _now()), op);
    }
  }

  Future<void> _deliver(
    CompanionInitiativeController controller,
    CompanionInitiativePresentation staged,
    _QueuedInitiative op,
    CompanionInitiativeRoom room,
    _SignalRequest request,
    String? reservation,
  ) async {
    final ticket = staged.display.ticket;
    var shown = false;
    var unknown = false;
    try {
      try {
        if (_requestCurrent(request)) shown = await request.deliver!(staged.display);
      } on Object {
        unknown = true;
      }
      if (!shown) {
        try {
          request.hide(ticket.id);
        } on Object {
          /* no evidence of absence */
        }
      }
      if (reservation != null) {
        _store!.settleInitiative(
          reservation,
          outcome: shown
              ? 'shown'
              : unknown
              ? 'unknown'
              : 'released',
        );
      }
      request.settled?.call(
        shown
            ? 'shown'
            : unknown
            ? 'unknown'
            : 'released',
      );
      if (!shown && !unknown) {
        _apply(controller, controller.handle(CompanionInitiativeEvent.dropOffer(ticket.id), _now()), op);
        return;
      }
      // The ledger spends a true or uncertain native delivery exactly once,
      // including a response that arrives after a window/switch changes.
      final committed = controller.commitPresentation(staged);
      if (committed.isEmpty) {
        _apply(controller, controller.handle(const CompanionInitiativeEvent.storageFault(), _now()), op);
        return;
      }
      if (shown && !_disposed) {
        _shownRoom = room;
        _shownSignal = request;
        _shownId = ticket.id;
        _arm(ticket.id, staged.display.expiresAtMono);
      }
      _apply(controller, committed.where((effect) => effect.type != CompanionInitiativeEffectType.show).toList(), op);
      if (unknown) _apply(controller, controller.handle(CompanionInitiativeEvent.dropOffer(ticket.id), _now()), op);
    } on Object {
      // A failed settlement leaves the original reservation occupied.
      _apply(controller, controller.handle(const CompanionInitiativeEvent.storageFault(), _now()), op);
    } finally {
      _waitingDelivery = false;
      _drain();
    }
  }

  void _prepare(CompanionInitiativeController controller, CompanionInitiativeTicket ticket, _SignalRequest request) {
    request.preparing = true;
    unawaited(() async {
      var ready = false;
      try {
        ready = await request.prepare!();
      } on Object {
        // Optional wording failures spend no presentation quota.
      }
      if (!identical(_signal, request)) {
        return;
      }
      if (!ready || !_requestCurrent(request) || controller.offer?.id != ticket.id) {
        cancelSignal(request.candidate.id);
        return;
      }
      request.prepared = true;
      _run(const CompanionInitiativeEvent.check());
    }());
  }

  void _hide(String id) {
    if (_expiryTicket == id) _disarm();
    if (_shownId != id) return;
    final room = _shownRoom;
    final request = _shownSignal;
    _shownRoom = null;
    _shownSignal = null;
    _shownId = null;
    try {
      if (request != null) {
        request.hide(id);
      } else {
        room?.hide(id);
      }
    } on Object {
      /* no quota refund */
    }
  }

  void _apply(CompanionInitiativeController controller, List<CompanionInitiativeEffect> effects, _QueuedInitiative op) {
    for (final effect in effects) {
      switch (effect.type) {
        case CompanionInitiativeEffectType.offer:
          _offer(controller, effect.ticket!, op);
        case CompanionInitiativeEffectType.show:
          throw StateError('Owner renders only staged presentation');
        case CompanionInitiativeEffectType.hide:
          _hide(effect.ticketId!);
        case CompanionInitiativeEffectType.updateTimeout:
          if (_shownId == effect.ticketId) {
            _arm(effect.ticketId!, effect.expiresAtMono);
            try {
              _shownRoom?.retime(effect.ticketId!, effect.expiresAtMono);
            } on Object {
              /* rendering only */
            }
          }
        case CompanionInitiativeEffectType.persist:
          _write(effect.record!);
        case CompanionInitiativeEffectType.restIntent:
          if (op.room != null && _same(op, op.room!, null)) op.room!.rest(effect);
        case CompanionInitiativeEffectType.cancelOffer:
          break;
      }
    }
  }

  void _write(CompanionInitiativeRecord record) {
    try {
      _store!.writeInitiativeMetadata(record.toJson());
    } on Object {
      _run(const CompanionInitiativeEvent.storageFault());
    }
  }

  static bool _quietLooking(CompanionInitiativeView? view) =>
      view != null && ((view.visible && view.resumed) || view.notificationAvailable) && !view.blocked && view.enabled;
  void _track(CompanionInitiativeEvent event) {
    final view = _view;
    final context = view?.contextKey;
    final restart =
        event.type == CompanionInitiativeEventType.userActivation ||
        event.type == CompanionInitiativeEventType.leave ||
        event.type == CompanionInitiativeEventType.accept ||
        event.type == CompanionInitiativeEventType.decline ||
        context != _trackedContext ||
        !identical(_room, _trackedRoom) ||
        !_quietLooking(view) ||
        _room == null;
    _trackedContext = context;
    _trackedRoom = _room;
    if (restart) {
      _quietSinceMono = null;
      _wokeForQuiet = null;
      if (!_quietLooking(view) || _room == null) return;
    }
    _quietSinceMono ??= _now().monoMs;
  }

  void _plan(CompanionInitiativeController controller) {
    final since = _quietSinceMono;
    if (_disposed ||
        controller.fault != null ||
        since == null ||
        since == _wokeForQuiet ||
        controller.display != null ||
        controller.offer != null) {
      _cancelQuietWake();
      return;
    }
    final now = _now();
    if (_disposed) return;
    final record = controller.record;
    var gate = 0;
    if (record != null) {
      final all = record.optionalAtMs;
      final recent = all.where((t) => t > now.wallMs - CompanionInitiativeRules.windowMs).toList();
      gate = max(gate, record.declinedUntilMs);
      if (all.isNotEmpty) gate = max(gate, all.last + controller.pace.gapMs);
      if (recent.length >= controller.pace.maxPerDay) {
        // Room again once enough of the day's lines have aged out.
        gate = max(gate, recent[recent.length - controller.pace.maxPerDay] + CompanionInitiativeRules.windowMs);
      }
    }
    var at = max<int>(since + controller.pace.quietMs, now.monoMs + max<int>(0, gate - now.wallMs));
    // Quiet/quotas may finish at night. Schedule the first eligible local day
    // boundary instead of spending this quiet stretch on a rejected check.
    final wallAt = now.wallMs + at - now.monoMs;
    // A safely encoded ledger can refuse until beyond DateTime's calendar.
    // Such a quota cannot reopen within the controller's valid clock range.
    if (wallAt > 8640000000000000 - 2 * CompanionInitiativeRules.windowMs) {
      _cancelQuietWake();
      return;
    }
    final local = DateTime.fromMillisecondsSinceEpoch(wallAt + now.offsetMinutes * 60000, isUtc: true);
    if (controller.enforceLocalQuietHours && (local.hour < 7 || local.hour >= 23)) {
      final day = DateTime.utc(local.year, local.month, local.day + (local.hour >= 23 ? 1 : 0), 7);
      at += day.millisecondsSinceEpoch - now.offsetMinutes * 60000 - wallAt;
    }
    if (_quietWake != null && _quietWakeAt == at) return;
    _cancelQuietWake();
    _quietWakeAt = at;
    _quietWake = Timer(Duration(milliseconds: max(0, at - now.monoMs)), () {
      _quietWake = null;
      _quietWakeAt = null;
      if (_disposed) return;
      final wokeAt = _now();
      if (_disposed) return;
      if (wokeAt.monoMs < at) {
        _plan(controller);
        return;
      }
      // A suspended process can resume after the planned daytime window.
      // The controller still validates both clocks before planning another day.
      if (!controller.enforceLocalQuietHours || companionNightKey(wokeAt.wallMs, wokeAt.offsetMinutes) == null) {
        _wokeForQuiet = since;
      }
      _run(const CompanionInitiativeEvent.check());
    });
  }

  void _cancelQuietWake() {
    _quietWake?.cancel();
    _quietWake = null;
    _quietWakeAt = null;
  }

  void _arm(String id, int? at) {
    _disarm();
    if (at == null) return;
    final left = max(0, at - _now().monoMs);
    if (_disposed) return;
    _expiryTicket = id;
    _expiry = Timer(Duration(milliseconds: left), () {
      _expiry = null;
      if (_disposed) return;
      if (_now().monoMs < at) {
        _arm(id, at);
        return;
      }
      _run(const CompanionInitiativeEvent.check());
    });
  }

  void _disarm() {
    _expiry?.cancel();
    _expiry = null;
    _expiryTicket = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_restored.isCompleted) _restored.complete();
    _revision++;
    _cancelQuietWake();
    _disarm();
    _retireRequest();
    _queue.clear();
    if (_shownId != null) _hide(_shownId!);
    _room = null;
    _view = null;
  }
}
