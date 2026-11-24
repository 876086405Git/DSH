import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notify/chat_alerts.dart';
import '../pets/pet_signals.dart';
import '../state/connection_state.dart';
import '../state/hosts_state.dart';
import 'companion_initiative.dart';
import 'companion_signal_consent.dart';
import 'companion_signals.dart';

/// The existing live, metadata-only ingress while the resident notification is
/// the active recipient. It neither replays history nor reads task bodies.
class CompanionResidentSignals {
  CompanionResidentSignals({
    required this.ref,
    required this.isCurrent,
    required this.isOwnSession,
    required this.offer,
    required CompanionInitiativeClock Function() clock,
  }) : gate = CompanionSignalGate(
         monotonicMs: () => clock().monoMs,
         utcNow: () => DateTime.fromMillisecondsSinceEpoch(clock().wallMs, isUtc: true),
       ) {
    _subscriptions.add(ref.listen(activeConnectionProvider, (_, _) => refresh()).close);
    _subscriptions.add(ref.listen(activeHostProvider, (_, _) => refresh()).close);
    _subscriptions.add(ref.listen(companionSignalConsentProvider, (_, _) => refresh()).close);
  }

  final Ref ref;
  final bool Function() isCurrent;
  final bool Function(String) isOwnSession;
  final void Function(CompanionSignalSpeech, bool Function()) offer;
  final CompanionSignalGate gate;
  final _subscriptions = <void Function()>[];
  StreamSubscription<CompanionAlertDelivery>? _deliveries;
  StreamSubscription? _generations;
  StreamSubscription? _states;
  DshClient? _client;
  CompanionSignalSource? _source;
  bool _entered = false;
  bool _closed = false;

  /// The visit observes every frame of a reply. Connection and consent
  /// already have their own listeners; only a recipient handoff needs work.
  void observeRecipient() {
    if (!_closed && isCurrent() != _entered) refresh();
  }

  void refresh() {
    if (_closed) return;
    if (!isCurrent()) {
      if (_entered) gate.leave();
      _entered = false;
      unawaited(_deliveries?.cancel());
      _deliveries = null;
      return;
    }
    if (!_entered) {
      _entered = true;
      gate.enter(recipientContext: this, ownerEpoch: Object());
    }
    final connection = ref.read(activeConnectionProvider).value;
    final client = connection?.client;
    if (!identical(client, _client)) {
      _client = client;
      unawaited(_generations?.cancel());
      unawaited(_states?.cancel());
      _generations = client?.mux.generations.listen((_) => refresh());
      _states = client?.mux.states.listen((_) => refresh());
    }
    final previous = _source;
    if (previous == null ||
        !identical(previous.connection, connection) ||
        !identical(previous.generation, client?.mux.generation)) {
      if (previous != null) gate.retireSource(previous);
      _source = null;
      if (connection != null && client != null && client.mux.generation != null) {
        try {
          late final CompanionSignalSource source;
          source = CompanionSignalSource.dsh(
            hostKey: companionHostKey(connection.isLocal ? HostRef.local : ref.read(activeHostProvider)),
            client: client,
            connection: connection,
            isAttached: () =>
                !_closed &&
                isCurrent() &&
                identical(_source, source) &&
                identical(ref.read(activeConnectionProvider).value, connection),
          );
          _source = source;
        } on ArgumentError {
          /* Only a real ready mux can supply this ingress. */
        }
      }
    }
    unawaited(_deliveries?.cancel());
    _deliveries = null;
    final source = _source;
    if (source == null) return;
    gate.setConsent(source, ref.read(companionSignalConsentProvider) ?? const CompanionSignalConsent());
    final ingress = gate.openIngress(source);
    if (ingress == null) return;
    _deliveries = ref.read(petEventBusProvider).companionSignals.listen((delivery) {
      if (_closed || !isCurrent()) return;
      final signal = delivery.signal;
      if (signal.kind != 'task.terminal' ||
          !const {'completed', 'output_limit', 'failed'}.contains(signal.payload['phase']) ||
          (signal.sessionId != null && isOwnSession(signal.sessionId!))) {
        return;
      }
      if (delivery.receive(gate, ingress) != CompanionSignalAdmission.accepted) return;
      final slot = gate.slots.where((slot) => identical(slot.signal, signal)).firstOrNull;
      final speech = slot == null ? null : gate.speechCandidate(slot);
      if (speech != null) offer(speech, () => !_closed && isCurrent() && gate.speechCurrent(speech));
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    gate.leave();
    for (final cancel in _subscriptions) {
      cancel();
    }
    unawaited(_deliveries?.cancel());
    unawaited(_generations?.cancel());
    unawaited(_states?.cancel());
  }
}
