// Local, silent greetings and cushion invitations. One controller belongs to
// the App installation, not to a host, page, session or WebView. The caller
// supplies observed eligibility and both clocks; this file performs no I/O.

const _maxSafeInteger = 9007199254740991;

abstract final class CompanionInitiativeRules {
  static const quietMs = 45000;
  static const promptMs = 8000;
  static const greetingGapMs = 30 * 60000;
  static const newStayAbsenceMs = 30 * 60000;
  static const inviteGapMs = 6 * 60 * 60000;
  static const windowMs = 24 * 60 * 60000;
  static const maxInvites = 2;
}

/// How often she may speak up unasked (「她多主动」, the person's pick): how
/// many invitations and signal lines in a day, how far apart, and how long
/// the person must be quiet first. At every pace she says nothing at night
/// and invites at most once a visit.
enum CompanionInitiativePace {
  rare(
    maxPerDay: CompanionInitiativeRules.maxInvites,
    gapMs: CompanionInitiativeRules.inviteGapMs,
    quietMs: CompanionInitiativeRules.quietMs,
  ),
  often(maxPerDay: 6, gapMs: 2 * 60 * 60000, quietMs: 30000),
  chatty(maxPerDay: 12, gapMs: 30 * 60000, quietMs: 20000);

  const CompanionInitiativePace({required this.maxPerDay, required this.gapMs, required this.quietMs});
  final int maxPerDay;
  final int gapMs;
  final int quietMs;

  /// What a saved record may hold, whatever pace it was written under.
  static const loosest = chatty;

  static CompanionInitiativePace? byName(String? name) => values.where((p) => p.name == name).firstOrNull;
}

class CompanionInitiativeClock {
  const CompanionInitiativeClock({required this.wallMs, required this.monoMs, this.offsetMinutes = 0});

  final int wallMs;
  final int monoMs;
  final int offsetMinutes;

  bool get _valid =>
      wallMs >= 0 &&
      monoMs >= 0 &&
      offsetMinutes >= -840 &&
      offsetMinutes <= 840 &&
      wallMs <= 8640000000000000 - 3 * CompanionInitiativeRules.windowMs &&
      monoMs <= _maxSafeInteger - CompanionInitiativeRules.windowMs;

  Map<String, Object?> toJson() => {'wallMs': wallMs, 'monoMs': monoMs};
}

/// Only use newLedger after storage has confirmed that the key is absent.
/// An unavailable or malformed ledger closes optional prompts for this owner.
class CompanionInitiativeRestore {
  const CompanionInitiativeRestore.newLedger() : _status = 'new', _value = null;
  const CompanionInitiativeRestore.loaded(Object? value) : _status = 'loaded', _value = value;
  const CompanionInitiativeRestore.unavailable() : _status = 'unavailable', _value = null;

  final String _status;
  final Object? _value;
}

int? _natural(Object? value) =>
    value is num && value.isFinite && value >= 0 && value <= _maxSafeInteger && value == value.toInt()
    ? value.toInt()
    : null;

int? _offset(Object? value) => value is int && value >= -840 && value <= 840 ? value : null;

String? companionNightKey(int wallMs, int offsetMinutes) {
  final local = DateTime.fromMillisecondsSinceEpoch(wallMs + offsetMinutes * 60000, isUtc: true);
  if (local.hour >= 7 && local.hour < 23) return null;
  final date = local.hour < 7 ? local.subtract(const Duration(days: 1)) : local;
  return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

int _nextNightBoundary(CompanionInitiativeClock now) {
  final local = DateTime.fromMillisecondsSinceEpoch(now.wallMs + now.offsetMinutes * 60000, isUtc: true);
  var boundary =
      DateTime.utc(local.year, local.month, local.day, 23).millisecondsSinceEpoch - now.offsetMinutes * 60000;
  if (boundary <= now.wallMs) boundary += CompanionInitiativeRules.windowMs;
  return boundary;
}

/// Stored with the shared budget; changing the timezone never clears its use.
class CompanionNightRecord {
  const CompanionNightRecord._(
    this.offsetMinutes,
    this.stableAfterMs,
    this.lastNightKey,
    this.lastNightAtMs,
    this.lastNightOffsetMinutes,
    this.changedSinceLast,
  );
  factory CompanionNightRecord.initial(int offset) => CompanionNightRecord._(offset, 0, null, null, null, false);
  final int offsetMinutes;
  final int stableAfterMs;
  final String? lastNightKey;
  final int? lastNightAtMs;
  final int? lastNightOffsetMinutes;
  final bool changedSinceLast;

  static CompanionNightRecord? read(Object? value) {
    const keys = {
      'offsetMinutes',
      'stableAfterMs',
      'lastNightKey',
      'lastNightAtMs',
      'lastNightOffsetMinutes',
      'changedSinceLast',
    };
    if (value is! Map || value.length != keys.length || value.keys.any((k) => !keys.contains(k))) return null;
    final offset = _offset(value['offsetMinutes']);
    final stable = _natural(value['stableAfterMs']);
    final key = value['lastNightKey'];
    final at = value['lastNightAtMs'];
    final lastOffset = value['lastNightOffsetMinutes'];
    final changed = value['changedSinceLast'];
    if (offset == null || stable == null || changed is! bool) return null;
    if (at == null) {
      if (key != null || lastOffset != null) return null;
    } else {
      if (_natural(at) == null || key is! String || _offset(lastOffset) == null) return null;
      try {
        if (companionNightKey((at as num).toInt(), lastOffset as int) != key) return null;
      } on Object {
        return null;
      }
      if (!changed && offset != lastOffset) return null;
    }
    return CompanionNightRecord._(
      offset,
      stable,
      key as String?,
      at == null ? null : (at as num).toInt(),
      lastOffset as int?,
      changed,
    );
  }

  CompanionNightRecord observe(CompanionInitiativeClock now) {
    if (now.offsetMinutes == offsetMinutes) return this;
    final boundary = _nextNightBoundary(now);
    return CompanionNightRecord._(
      now.offsetMinutes,
      boundary > stableAfterMs ? boundary : stableAfterMs,
      lastNightKey,
      lastNightAtMs,
      lastNightOffsetMinutes,
      true,
    );
  }

  bool allows(String key, CompanionInitiativeClock now) =>
      offsetMinutes == now.offsetMinutes &&
      now.wallMs >= stableAfterMs &&
      key == companionNightKey(now.wallMs, now.offsetMinutes) &&
      key != lastNightKey &&
      (!changedSinceLast || lastNightAtMs == null || now.wallMs - lastNightAtMs! >= CompanionInitiativeRules.windowMs);

  CompanionNightRecord used(String key, CompanionInitiativeClock now) =>
      CompanionNightRecord._(offsetMinutes, stableAfterMs, key, now.wallMs, now.offsetMinutes, false);
  Map<String, Object?> toJson() => {
    'offsetMinutes': offsetMinutes,
    'stableAfterMs': stableAfterMs,
    'lastNightKey': lastNightKey,
    'lastNightAtMs': lastNightAtMs,
    'lastNightOffsetMinutes': lastNightOffsetMinutes,
    'changedSinceLast': changedSinceLast,
  };
}

class CompanionInitiativeRecord {
  CompanionInitiativeRecord._(
    this.lastGreetingAtMs,
    List<int> invites,
    this.declinedUntilMs, [
    List<int> signals = const [],
    this.night,
  ]) : inviteAtMs = List.unmodifiable(invites),
       signalAtMs = List.unmodifiable(signals);
  final int? lastGreetingAtMs;
  final List<int> inviteAtMs;
  final List<int> signalAtMs;
  final int declinedUntilMs;
  final CompanionNightRecord? night;
  List<int> get optionalAtMs => [...inviteAtMs, ...signalAtMs]..sort();

  static CompanionInitiativeRecord? _read(Object? value) {
    const v1 = {'v', 'lastGreetingAtMs', 'inviteAtMs', 'declinedUntilMs'};
    const v2 = {...v1, 'signalAtMs', 'night'};
    if (value is! Map || (value['v'] != 1 && value['v'] != 2)) return null;
    final keys = value['v'] == 1 ? v1 : v2;
    if (value.length != keys.length || value.keys.any((k) => !keys.contains(k))) return null;
    final last = value['lastGreetingAtMs'];
    final declined = _natural(value['declinedUntilMs']);
    if ((last != null && _natural(last) == null) || declined == null) return null;
    List<int>? times(Object? raw) {
      if (raw is! List || raw.length > CompanionInitiativePace.loosest.maxPerDay) return null;
      final result = <int>[];
      for (final v in raw) {
        final t = _natural(v);
        if (t == null || (result.isNotEmpty && t - result.last < CompanionInitiativePace.loosest.gapMs)) return null;
        result.add(t);
      }
      return result;
    }

    final invites = times(value['inviteAtMs']);
    final signals = value['v'] == 1 ? <int>[] : times(value['signalAtMs']);
    if (invites == null || signals == null) return null;
    final all = [...invites, ...signals]..sort();
    if (all.length > CompanionInitiativePace.loosest.maxPerDay) return null;
    for (var i = 1; i < all.length; i++) {
      if (all[i] - all[i - 1] < CompanionInitiativePace.loosest.gapMs) return null;
    }
    final rawNight = value['night'];
    final night = rawNight == null ? null : CompanionNightRecord.read(rawNight);
    if (rawNight != null && night == null) return null;
    return CompanionInitiativeRecord._(last == null ? null : _natural(last), invites, declined, signals, night);
  }

  Map<String, Object?> toJson() => {
    'v': 2,
    'lastGreetingAtMs': lastGreetingAtMs,
    'inviteAtMs': List<int>.of(inviteAtMs),
    'signalAtMs': List<int>.of(signalAtMs),
    'declinedUntilMs': declinedUntilMs,
    'night': night?.toJson(),
  };
}

/// Opaque local candidate identity; never a raw remote DTO or model prompt.
class CompanionInitiativeSignal {
  const CompanionInitiativeSignal({
    required this.id,
    required this.contextKey,
    required this.expiresAtMonoMs,
    this.nightKey,
  });
  final String id;
  final String contextKey;
  final int expiresAtMonoMs;
  final String? nightKey;
}

/// A complete current observation. contextKey changes on a real mode, binding
/// or view replacement, never on each build, revision or asOf update.
class CompanionInitiativeView {
  const CompanionInitiativeView({
    required this.visible,
    required this.resumed,
    required this.blocked,
    required this.enabled,
    required this.accessible,
    required this.contextKey,
    this.notificationAvailable = false,
  });

  /// Combine independently observed gates; do not include this controller's
  /// own greeting/invitation slot in externalPromptBusy.
  factory CompanionInitiativeView.room({
    required bool routeVisible,
    required bool stageReady,
    required bool resumed,
    required bool inputBusy,
    required bool generating,
    required bool audioBusy,
    required bool activityBusy,
    required bool approvalPending,
    required bool externalPromptBusy,
    required bool quietHoursBlocked,
    required bool enabled,
    required bool accessible,
    required String contextKey,
  }) => CompanionInitiativeView(
    visible: routeVisible && stageReady,
    resumed: resumed,
    blocked:
        inputBusy ||
        generating ||
        audioBusy ||
        activityBusy ||
        approvalPending ||
        externalPromptBusy ||
        quietHoursBlocked,
    enabled: enabled,
    accessible: accessible,
    contextKey: contextKey,
  );

  final bool visible;
  final bool resumed;
  final bool blocked;
  final bool enabled;
  final bool accessible;
  final String contextKey;

  /// A retained background conversation can deliver signals, not room greetings
  /// or cushion invitations. It is never counted as visible/resumed presence.
  final bool notificationAvailable;

  Map<String, Object?> toJson() => {
    'visible': visible,
    'resumed': resumed,
    'blocked': blocked,
    'enabled': enabled,
    'accessible': accessible,
    'contextKey': contextKey,
    if (notificationAvailable) 'notificationAvailable': true,
  };
}

enum CompanionInitiativeEventType {
  enter,
  leave,
  observe,
  userActivation,
  check,
  present,
  dropOffer,
  accept,
  decline,
  storageFault,
  signal,
  cancelSignal,
}

class CompanionInitiativeEvent {
  const CompanionInitiativeEvent.enter(CompanionInitiativeView view)
    : this._(CompanionInitiativeEventType.enter, view: view);
  const CompanionInitiativeEvent.leave() : this._(CompanionInitiativeEventType.leave);
  const CompanionInitiativeEvent.observe(CompanionInitiativeView view)
    : this._(CompanionInitiativeEventType.observe, view: view);
  const CompanionInitiativeEvent.userActivation() : this._(CompanionInitiativeEventType.userActivation);
  const CompanionInitiativeEvent.check() : this._(CompanionInitiativeEventType.check);
  const CompanionInitiativeEvent.present(String ticketId)
    : this._(CompanionInitiativeEventType.present, ticketId: ticketId);
  const CompanionInitiativeEvent.dropOffer(String ticketId)
    : this._(CompanionInitiativeEventType.dropOffer, ticketId: ticketId);
  const CompanionInitiativeEvent.accept(String ticketId)
    : this._(CompanionInitiativeEventType.accept, ticketId: ticketId);
  const CompanionInitiativeEvent.decline([String? ticketId])
    : this._(CompanionInitiativeEventType.decline, ticketId: ticketId);
  const CompanionInitiativeEvent.storageFault() : this._(CompanionInitiativeEventType.storageFault);

  const CompanionInitiativeEvent.signal(
    CompanionInitiativeSignal signal, {
    bool nightCareEnabled = false,
    CompanionInitiativeView? view,
  }) : this._(CompanionInitiativeEventType.signal, signal: signal, nightCareEnabled: nightCareEnabled, view: view);
  const CompanionInitiativeEvent.cancelSignal(String id)
    : this._(CompanionInitiativeEventType.cancelSignal, signalId: id);
  const CompanionInitiativeEvent._(
    this.type, {
    this.view,
    this.ticketId,
    this.signal,
    this.signalId,
    this.nightCareEnabled = false,
  });
  final CompanionInitiativeEventType type;
  final CompanionInitiativeView? view;
  final String? ticketId;
  final CompanionInitiativeSignal? signal;
  final String? signalId;
  final bool nightCareEnabled;
}

enum CompanionPromptKind { greeting, invite, signal }

class CompanionInitiativeTicket {
  const CompanionInitiativeTicket._(this.id, this.kind, this.ownerEpoch, this.stayId, this.contextKey, [this.signalId]);

  final String id;
  final CompanionPromptKind kind;
  final int ownerEpoch;
  final int stayId;
  final String? signalId;
  final String contextKey;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'ownerEpoch': ownerEpoch,
    'stayId': stayId,
    'signalId': ?signalId,
    'contextKey': contextKey,
  };
}

class CompanionInitiativeDisplay {
  const CompanionInitiativeDisplay._(this.ticket, this.committedAtWallMs, this.expiresAtMono);

  final CompanionInitiativeTicket ticket;
  final int committedAtWallMs;
  final int? expiresAtMono;

  Map<String, Object?> toJson() => {
    ...ticket.toJson(),
    'committedAtWallMs': committedAtWallMs,
    'expiresAtMono': expiresAtMono,
  };
}

enum CompanionInitiativeEffectType { offer, cancelOffer, show, hide, updateTimeout, persist, restIntent }

class CompanionInitiativeEffect {
  const CompanionInitiativeEffect._(
    this.type, {
    this.ticket,
    this.display,
    this.ticketId,
    this.reason,
    this.expiresAtMono,
    this.record,
    this.contextKey,
    this.ownerEpoch,
  });

  final CompanionInitiativeEffectType type;
  final CompanionInitiativeTicket? ticket;
  final CompanionInitiativeDisplay? display;
  final String? ticketId;
  final String? reason;
  final int? expiresAtMono;
  final CompanionInitiativeRecord? record;
  final String? contextKey;
  final int? ownerEpoch;

  Map<String, Object?> toJson() => switch (type) {
    CompanionInitiativeEffectType.offer => {'type': type.name, 'ticket': ticket!.toJson()},
    CompanionInitiativeEffectType.show => {
      'type': type.name,
      'display': display!.toJson(),
      'silent': display!.ticket.kind != CompanionPromptKind.signal,
      'autoAnnounce': false,
    },
    CompanionInitiativeEffectType.cancelOffer ||
    CompanionInitiativeEffectType.hide => {'type': type.name, 'ticketId': ticketId, 'reason': reason},
    CompanionInitiativeEffectType.updateTimeout => {
      'type': type.name,
      'ticketId': ticketId,
      'expiresAtMono': expiresAtMono,
    },
    CompanionInitiativeEffectType.persist => {'type': type.name, 'value': record!.toJson()},
    CompanionInitiativeEffectType.restIntent => {
      'type': type.name,
      'ticketId': ticketId,
      'contextKey': contextKey,
      'ownerEpoch': ownerEpoch,
    },
  };
}

class _Stay {
  _Stay(this.id) : interacted = false, invited = false;
  _Stay.copy(_Stay value) : id = value.id, interacted = value.interacted, invited = value.invited;

  final int id;
  bool interacted;
  bool invited;
  Map<String, Object?> toJson() => {'id': id, 'interacted': interacted, 'invited': invited};
}

class _State {
  _State(this.lastNow, CompanionInitiativeRestore restored) {
    if (restored._status == 'new') {
      record = CompanionInitiativeRecord._(null, [], 0);
    } else if (restored._status != 'loaded') {
      fault = 'ledger-unavailable';
    } else {
      record = CompanionInitiativeRecord._read(restored._value);
      if (record == null) {
        fault = 'ledger-invalid';
      } else if ((record!.lastGreetingAtMs != null && record!.lastGreetingAtMs! > lastNow.wallMs) ||
          record!.optionalAtMs.any((t) => t > lastNow.wallMs) ||
          (record!.night?.lastNightAtMs != null && record!.night!.lastNightAtMs! > lastNow.wallMs)) {
        fault = 'history-in-future';
      }
    }
    if (record != null) {
      optionalMonos = record!.optionalAtMs.map((t) => lastNow.monoMs - (lastNow.wallMs - t)).toList();
      declinedUntilMono =
          lastNow.monoMs + (record!.declinedUntilMs > lastNow.wallMs ? record!.declinedUntilMs - lastNow.wallMs : 0);
    }
  }

  _State.copy(_State value)
    : record = value.record,
      fault = value.fault,
      lastNow = value.lastNow,
      inRoom = value.inRoom,
      outsideSinceMono = value.outsideSinceMono,
      view = value.view,
      ownerEpoch = value.ownerEpoch,
      nextStay = value.nextStay,
      nextTicket = value.nextTicket,
      stay = value.stay == null ? null : _Stay.copy(value.stay!),
      quietSinceMono = value.quietSinceMono,
      ticket = value.ticket,
      display = value.display,
      signal = value.signal,
      nightCareEnabled = value.nightCareEnabled,
      signalQuietSinceMono = value.signalQuietSinceMono,
      optionalMonos = List.of(value.optionalMonos),
      declinedUntilMono = value.declinedUntilMono;

  CompanionInitiativeRecord? record;
  String? fault;
  CompanionInitiativeClock lastNow;
  CompanionInitiativeSignal? signal;
  bool nightCareEnabled = false;
  int? signalQuietSinceMono;
  List<int> optionalMonos = [];
  int declinedUntilMono = 0;
  bool inRoom = false;
  int? outsideSinceMono;
  CompanionInitiativeView? view;
  int ownerEpoch = 0;
  int nextStay = 1;
  int nextTicket = 1;
  _Stay? stay;
  int? quietSinceMono;
  CompanionInitiativeTicket? ticket;
  CompanionInitiativeDisplay? display;

  bool get eligible =>
      fault == null && inRoom && (view?.visible ?? false) && view!.resumed && !view!.blocked && view!.enabled;
  bool get signalEligible =>
      eligible || (fault == null && inRoom && view?.notificationAvailable == true && !view!.blocked && view!.enabled);
  bool get quietEligible => eligible && stay != null && !stay!.interacted && !stay!.invited;

  Map<String, Object?> toJson() => {
    'record': record?.toJson(),
    'fault': fault,
    'lastNow': lastNow.toJson(),
    'inRoom': inRoom,
    'outsideSinceMono': outsideSinceMono,
    'view': view?.toJson(),
    'ownerEpoch': ownerEpoch,
    'nextStay': nextStay,
    'nextTicket': nextTicket,
    'stay': stay?.toJson(),
    'quietSinceMono': quietSinceMono,
    'ticket': ticket?.toJson(),
    'display': display?.toJson(),
  };
}

/// Synchronous transitions install the latest state before returning effects.
/// Host/mode bindings, lifecycle observations, rendering and serialized ledger
/// writes remain the App owner's responsibility. This is not a multiwriter lock.
class CompanionInitiativeController {
  CompanionInitiativeController({
    required CompanionInitiativeClock now,
    required CompanionInitiativeRestore restored,
    this.enforceLocalQuietHours = true,
  }) {
    if (!now._valid) throw ArgumentError('Expected safe nonnegative wallMs and monoMs');
    _state = _State(now, restored);
  }

  final bool enforceLocalQuietHours;

  /// The person's pick; a change applies from the next check on.
  CompanionInitiativePace pace = CompanionInitiativePace.rare;
  late _State _state;
  CompanionInitiativeSignal? get pendingSignal => _state.signal;
  String? get fault => _state.fault;
  CompanionInitiativeRecord? get record => _state.record;
  CompanionInitiativeTicket? get offer => _state.ticket;
  CompanionInitiativeDisplay? get display => _state.display;

  /// Detached diagnostic state, including ephemeral context. Persist only the
  /// record supplied by a persist effect, not this process-local snapshot.
  Map<String, Object?> inspect() => _state.toJson();

  List<CompanionInitiativeEffect> handle(CompanionInitiativeEvent event, CompanionInitiativeClock now) {
    final s = _State.copy(_state);
    final effects = <CompanionInitiativeEffect>[];
    if (!now._valid ||
        now.monoMs < s.lastNow.monoMs ||
        now.wallMs < s.lastNow.wallMs ||
        (enforceLocalQuietHours && ((now.wallMs - s.lastNow.wallMs) - (now.monoMs - s.lastNow.monoMs)).abs() > 1000)) {
      _block(s, effects, 'clock-invalid-or-regressed');
      _state = s;
      return List.unmodifiable(effects);
    }
    if (enforceLocalQuietHours && s.fault == null && s.record != null) {
      final r = s.record!;
      final night = (r.night ?? CompanionNightRecord.initial(s.lastNow.offsetMinutes)).observe(now);
      if (!identical(night, r.night)) {
        s.record = CompanionInitiativeRecord._(
          r.lastGreetingAtMs,
          r.inviteAtMs,
          r.declinedUntilMs,
          r.signalAtMs,
          night,
        );
        _persist(s, effects);
      }
    }
    s.lastNow = now;
    final viewEvent =
        event.type == CompanionInitiativeEventType.enter || event.type == CompanionInitiativeEventType.observe;
    if (!viewEvent) _expire(s, now, effects);

    switch (event.type) {
      case CompanionInitiativeEventType.enter:
        final wasInRoom = s.inRoom;
        final newStay =
            s.stay == null ||
            (!wasInRoom &&
                s.outsideSinceMono != null &&
                now.monoMs - s.outsideSinceMono! >= CompanionInitiativeRules.newStayAbsenceMs);
        if (!wasInRoom) {
          s.inRoom = true;
          s.ownerEpoch++;
          s.quietSinceMono = null;
          _cancel(s, effects, 'enter');
        }
        s.outsideSinceMono = null;
        _applyView(s, event.view!, now, effects);
        if (newStay) {
          s.stay = _Stay(s.nextStay++);
          // A greeting is evaluated only here. It is not retried after awaits.
          if (s.eligible && _greetingAllows(s, now.wallMs)) _offer(s, CompanionPromptKind.greeting, effects);
        }
      case CompanionInitiativeEventType.leave:
        if (s.inRoom) {
          s.inRoom = false;
          s.outsideSinceMono = now.monoMs;
          s.ownerEpoch++;
          s.quietSinceMono = null;
          _cancel(s, effects, 'leave');
        }
      case CompanionInitiativeEventType.observe:
        _applyView(s, event.view!, now, effects);
      case CompanionInitiativeEventType.userActivation:
        _userAction(s, effects);
      case CompanionInitiativeEventType.dropOffer:
        if (s.display?.ticket.id == event.ticketId) {
          // An uncertain render consumes its quota but owns no visible slot.
          _cancel(s, effects, 'presentation-unconfirmed');
        }
        if (s.ticket?.id == event.ticketId) {
          effects.add(
            CompanionInitiativeEffect._(
              CompanionInitiativeEffectType.cancelOffer,
              ticketId: s.ticket!.id,
              reason: 'adapter-discarded',
            ),
          );
          if (s.ticket!.kind == CompanionPromptKind.signal) s.signal = null;
          s.ticket = null;
        }
      case CompanionInitiativeEventType.decline:
        if (!s.inRoom || (event.ticketId != null && !_currentOptional(s, event.ticketId))) break;
        _userAction(s, effects);
        if (s.fault == null && s.record != null) {
          final r = s.record!;
          final deadline = now.wallMs + pace.gapMs;
          s.record = CompanionInitiativeRecord._(
            r.lastGreetingAtMs,
            r.inviteAtMs,
            deadline > r.declinedUntilMs ? deadline : r.declinedUntilMs,
            r.signalAtMs,
            r.night,
          );
          final monoDeadline = now.monoMs + pace.gapMs;
          if (monoDeadline > s.declinedUntilMono) s.declinedUntilMono = monoDeadline;
          _persist(s, effects);
        }
      case CompanionInitiativeEventType.accept:
        if (!s.eligible || !_currentInvite(s, event.ticketId)) break;
        final accepted = s.display!.ticket;
        _userAction(s, effects);
        effects.add(
          CompanionInitiativeEffect._(
            CompanionInitiativeEffectType.restIntent,
            ticketId: accepted.id,
            contextKey: accepted.contextKey,
            ownerEpoch: accepted.ownerEpoch,
          ),
        );
      case CompanionInitiativeEventType.present:
        final ticket = s.ticket;
        if (ticket == null || ticket.id != event.ticketId) break;
        s.ticket = null;
        final current =
            (ticket.kind == CompanionPromptKind.signal ? s.signalEligible : s.eligible) &&
            s.display == null &&
            ticket.ownerEpoch == s.ownerEpoch &&
            ticket.stayId == s.stay?.id &&
            ticket.contextKey == s.view!.contextKey;
        final allowed =
            current &&
            (ticket.kind == CompanionPromptKind.greeting
                ? _greetingAllows(s, now.wallMs)
                : ticket.kind == CompanionPromptKind.signal
                ? ticket.signalId == s.signal?.id && _signalAllows(s, now)
                : s.quietEligible &&
                      s.quietSinceMono != null &&
                      now.monoMs - s.quietSinceMono! >= pace.quietMs &&
                      _inviteAllows(s, now.wallMs) &&
                      _dayAllows(now));
        if (!allowed) {
          effects.add(
            CompanionInitiativeEffect._(
              CompanionInitiativeEffectType.cancelOffer,
              ticketId: ticket.id,
              reason: 'present-rejected',
            ),
          );
          break;
        }
        final r = s.record!;
        if (ticket.kind == CompanionPromptKind.greeting) {
          s.record = CompanionInitiativeRecord._(now.wallMs, r.inviteAtMs, r.declinedUntilMs, r.signalAtMs, r.night);
        } else {
          final recentInvites = r.inviteAtMs.where((t) => t > now.wallMs - CompanionInitiativeRules.windowMs).toList();
          final recentSignals = r.signalAtMs.where((t) => t > now.wallMs - CompanionInitiativeRules.windowMs).toList();
          var night = r.night;
          if (ticket.kind == CompanionPromptKind.signal) {
            recentSignals.add(now.wallMs);
            if (s.signal!.nightKey != null) night = night!.used(s.signal!.nightKey!, now);
          } else {
            recentInvites.add(now.wallMs);
            s.stay!.invited = true;
          }
          s.record = CompanionInitiativeRecord._(
            r.lastGreetingAtMs,
            recentInvites,
            r.declinedUntilMs,
            recentSignals,
            night,
          );
          s.optionalMonos = [
            ...s.optionalMonos.where((t) => t > now.monoMs - CompanionInitiativeRules.windowMs),
            now.monoMs,
          ];
        }
        s.display = CompanionInitiativeDisplay._(ticket, now.wallMs, _displayExpiry(s, ticket, now));
        effects.add(CompanionInitiativeEffect._(CompanionInitiativeEffectType.show, display: s.display));
        _persist(s, effects);
      case CompanionInitiativeEventType.signal:
        if (event.view != null) _applyView(s, event.view!, now, effects);
        final signal = event.signal!;
        if (!s.signalEligible ||
            s.display != null ||
            signal.id.isEmpty ||
            signal.contextKey != s.view!.contextKey ||
            signal.expiresAtMonoMs <= now.monoMs ||
            signal.expiresAtMonoMs - now.monoMs > 120000) {
          break;
        }
        if (s.signal?.id == signal.id) break;
        if (s.ticket?.kind == CompanionPromptKind.invite || s.ticket?.kind == CompanionPromptKind.signal) {
          effects.add(
            CompanionInitiativeEffect._(
              CompanionInitiativeEffectType.cancelOffer,
              ticketId: s.ticket!.id,
              reason: 'signal-replaced-offer',
            ),
          );
          s.ticket = null;
        }
        s.signal = signal;
        s.nightCareEnabled = event.nightCareEnabled;
      case CompanionInitiativeEventType.cancelSignal:
        if (s.signal?.id == event.signalId) _retireSignal(s, effects, 'signal-withdrawn');
      case CompanionInitiativeEventType.storageFault:
        _block(s, effects, 'storage-failed');
      case CompanionInitiativeEventType.check:
        break;
    }
    if (viewEvent) _expire(s, now, effects);
    if (!s.quietEligible) {
      s.quietSinceMono = null;
    } else {
      s.quietSinceMono ??= now.monoMs;
    }
    if (!s.signalEligible) {
      s.signalQuietSinceMono = null;
    } else {
      s.signalQuietSinceMono ??= now.monoMs;
    }
    // Stale button/present callbacks never manufacture a fresh ticket.
    if (viewEvent ||
        event.type == CompanionInitiativeEventType.check ||
        event.type == CompanionInitiativeEventType.signal) {
      if (_signalAllows(s, now)) _offer(s, CompanionPromptKind.signal, effects);
      if (s.signal == null &&
          s.quietEligible &&
          _dayAllows(now) &&
          s.quietSinceMono != null &&
          now.monoMs - s.quietSinceMono! >= pace.quietMs &&
          _inviteAllows(s, now.wallMs)) {
        _offer(s, CompanionPromptKind.invite, effects);
      }
    }
    _state = s;
    return List.unmodifiable(effects);
  }

  static void _cancel(_State s, List<CompanionInitiativeEffect> effects, String reason) {
    if (s.ticket != null) {
      effects.add(
        CompanionInitiativeEffect._(CompanionInitiativeEffectType.cancelOffer, ticketId: s.ticket!.id, reason: reason),
      );
    }
    if (s.display != null) {
      effects.add(
        CompanionInitiativeEffect._(CompanionInitiativeEffectType.hide, ticketId: s.display!.ticket.id, reason: reason),
      );
    }
    s.ticket = null;
    s.display = null;
    s.signal = null;
    s.signalQuietSinceMono = null;
  }

  static void _block(_State s, List<CompanionInitiativeEffect> effects, String reason) {
    s.fault ??= reason;
    s.quietSinceMono = null;
    _cancel(s, effects, reason);
  }

  static void _applyView(
    _State s,
    CompanionInitiativeView view,
    CompanionInitiativeClock now,
    List<CompanionInitiativeEffect> effects,
  ) {
    if (view.contextKey.isEmpty) throw ArgumentError('Expected a nonempty contextKey');
    if (s.view?.contextKey != view.contextKey) {
      s.ownerEpoch++;
      s.quietSinceMono = null;
      _cancel(s, effects, 'context-changed');
    }
    final oldAccessible = s.view?.accessible;
    s.view = view;
    if (!s.signalEligible) {
      s.quietSinceMono = null;
      _cancel(s, effects, 'not-presentable');
    } else if (s.display != null && oldAccessible != view.accessible) {
      final display = s.display!;
      final expiry = _displayExpiry(s, display.ticket, now);
      s.display = CompanionInitiativeDisplay._(display.ticket, display.committedAtWallMs, expiry);
      effects.add(
        CompanionInitiativeEffect._(
          CompanionInitiativeEffectType.updateTimeout,
          ticketId: display.ticket.id,
          expiresAtMono: expiry,
        ),
      );
    }
  }

  static void _offer(_State s, CompanionPromptKind kind, List<CompanionInitiativeEffect> effects) {
    if (s.ticket != null || s.display != null) return;
    s.ticket = CompanionInitiativeTicket._(
      '${s.nextTicket++}',
      kind,
      s.ownerEpoch,
      s.stay!.id,
      s.view!.contextKey,
      kind == CompanionPromptKind.signal ? s.signal?.id : null,
    );
    effects.add(CompanionInitiativeEffect._(CompanionInitiativeEffectType.offer, ticket: s.ticket));
  }

  static List<int> _recent(CompanionInitiativeRecord record, int wallMs) =>
      record.optionalAtMs.where((t) => t > wallMs - CompanionInitiativeRules.windowMs).toList();

  bool _inviteAllows(_State s, int wallMs) {
    final r = s.record;
    if (r == null || wallMs < r.declinedUntilMs || s.lastNow.monoMs < s.declinedUntilMono) return false;
    final all = r.optionalAtMs;
    final mono = s.optionalMonos.where((t) => t > s.lastNow.monoMs - CompanionInitiativeRules.windowMs).toList();
    return _recent(r, wallMs).length < pace.maxPerDay &&
        (all.isEmpty || wallMs - all.last >= pace.gapMs) &&
        mono.length < pace.maxPerDay &&
        (s.optionalMonos.isEmpty || s.lastNow.monoMs - s.optionalMonos.last >= pace.gapMs);
  }

  static bool _greetingAllows(_State s, int wallMs) =>
      s.record != null &&
      (s.record!.lastGreetingAtMs == null ||
          wallMs - s.record!.lastGreetingAtMs! >= CompanionInitiativeRules.greetingGapMs);

  static void _persist(_State s, List<CompanionInitiativeEffect> effects) =>
      effects.add(CompanionInitiativeEffect._(CompanionInitiativeEffectType.persist, record: s.record));

  static void _userAction(_State s, List<CompanionInitiativeEffect> effects) {
    if (!s.inRoom || s.stay == null) return;
    s.stay!.interacted = true;
    s.quietSinceMono = null;
    _cancel(s, effects, 'user-action');
  }

  static bool _currentOptional(_State s, String? id) =>
      s.display?.ticket.id == id &&
      s.display != null &&
      s.display!.ticket.kind != CompanionPromptKind.greeting &&
      s.display!.ticket.ownerEpoch == s.ownerEpoch &&
      s.display!.ticket.stayId == s.stay?.id;

  static bool _currentInvite(_State s, String? id) =>
      _currentOptional(s, id) && s.display!.ticket.kind == CompanionPromptKind.invite;

  static void _expire(_State s, CompanionInitiativeClock now, List<CompanionInitiativeEffect> effects) {
    if (s.signal != null &&
        (now.monoMs >= s.signal!.expiresAtMonoMs ||
            s.signal!.contextKey != s.view?.contextKey ||
            (s.signal!.nightKey != null && companionNightKey(now.wallMs, now.offsetMinutes) != s.signal!.nightKey))) {
      _retireSignal(s, effects, 'signal-expired');
    }
    final display = s.display;
    if (display != null && display.expiresAtMono != null && now.monoMs >= display.expiresAtMono!) {
      effects.add(
        CompanionInitiativeEffect._(CompanionInitiativeEffectType.hide, ticketId: display.ticket.id, reason: 'timeout'),
      );
      s.display = null;
      if (display.ticket.kind == CompanionPromptKind.signal) s.signal = null;
    }
  }

  bool _dayAllows(CompanionInitiativeClock now) =>
      !enforceLocalQuietHours || companionNightKey(now.wallMs, now.offsetMinutes) == null;

  bool _signalAllows(_State s, CompanionInitiativeClock now) {
    final candidate = s.signal;
    if (candidate == null ||
        !s.signalEligible ||
        s.signalQuietSinceMono == null ||
        now.monoMs - s.signalQuietSinceMono! < pace.quietMs ||
        now.monoMs >= candidate.expiresAtMonoMs ||
        candidate.contextKey != s.view?.contextKey ||
        !_inviteAllows(s, now.wallMs)) {
      return false;
    }
    if (candidate.nightKey != null) {
      return s.nightCareEnabled && (s.record?.night?.allows(candidate.nightKey!, now) ?? false);
    }
    return _dayAllows(now);
  }

  static int? _displayExpiry(_State s, CompanionInitiativeTicket ticket, CompanionInitiativeClock now) {
    final usual = s.view!.accessible ? null : now.monoMs + CompanionInitiativeRules.promptMs;
    if (ticket.kind != CompanionPromptKind.signal) return usual;
    final expiry = s.signal!.expiresAtMonoMs;
    return usual == null || expiry < usual ? expiry : usual;
  }

  static void _retireSignal(_State s, List<CompanionInitiativeEffect> effects, String reason) {
    final id = s.signal?.id;
    if (id == null) return;
    if (s.ticket?.signalId == id) {
      effects.add(
        CompanionInitiativeEffect._(CompanionInitiativeEffectType.cancelOffer, ticketId: s.ticket!.id, reason: reason),
      );
      s.ticket = null;
    }
    if (s.display?.ticket.signalId == id) {
      effects.add(
        CompanionInitiativeEffect._(CompanionInitiativeEffectType.hide, ticketId: s.display!.ticket.id, reason: reason),
      );
      s.display = null;
    }
    s.signal = null;
  }

  /// Stage pure effects, without installing quota or a displayed slot.
  CompanionInitiativePresentation? stagePresentation(String ticketId, CompanionInitiativeClock now) {
    final before = _state;
    final effects = handle(CompanionInitiativeEvent.present(ticketId), now);
    final after = _state;
    _state = before;
    if (!effects.any((e) => e.type == CompanionInitiativeEffectType.show)) {
      if (after.fault != null) _state = after;
      return null;
    }
    return CompanionInitiativePresentation._(this, before, after, effects);
  }

  List<CompanionInitiativeEffect> commitPresentation(CompanionInitiativePresentation staged) {
    if (!identical(staged._controller, this) || staged._used || !identical(staged._before, _state)) return const [];
    staged._used = true;
    _state = staged._after;
    return staged._effects;
  }
}

class CompanionInitiativePresentation {
  CompanionInitiativePresentation._(this._controller, this._before, this._after, this._effects);
  final CompanionInitiativeController _controller;
  final _State _before;
  final _State _after;
  final List<CompanionInitiativeEffect> _effects;
  bool _used = false;
  CompanionInitiativeDisplay get display =>
      _effects.singleWhere((e) => e.type == CompanionInitiativeEffectType.show).display!;
}
