// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
// Adapted from ds-harness-remote 77604776 packages/webrtc/src/control-lease.ts.

import 'dart:async';

import '../protocol/control.dart';
import '../util/bytes.dart';

/// Socket traffic does not renew authorization. Only a matching, timely ack
/// confirms the ticket. Both elapsed and wall time bound background suspension.
class ControlLease {
  ControlLease(this.connectionId, this._ticket, this._request, this._expired);

  final String connectionId;
  final bool Function(JsonMap payload) _request;
  final void Function() _expired;
  final Stopwatch _clock = Stopwatch()..start();

  // start/ack set the deadline; stop/expiry retire it. A new tunnel creates a
  // new lease, never reuses this ticket or its request sequence.
  String _ticket;
  bool _confirmed = false;
  int _sequence = 0;
  int _deadlineMono = 0;
  int _deadlineWall = 0;
  int? _lastRequest;
  ({String id, int mono, int wall})? _sent;
  Timer? _timer;

  void start() {
    final mono = _clock.elapsedMilliseconds;
    _deadlineMono = mono + controlLeaseMs;
    _deadlineWall = DateTime.now().millisecondsSinceEpoch + controlLeaseMs;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    tick(force: true);
  }

  bool get isValid {
    if (_timer == null) return false;
    if (_clock.elapsedMilliseconds >= _deadlineMono || DateTime.now().millisecondsSinceEpoch >= _deadlineWall) {
      stop();
      _expired();
      return false;
    }
    return true;
  }

  bool get canDetach => _confirmed && isValid;
  String? get recoveryTicket => canDetach ? _ticket : null;

  /// Losing a socket retires its outstanding request, not the authorization
  /// deadline. Recovery hello must finish before another request can be sent.
  void controlLost() => _sent = null;

  void tick({bool force = false}) {
    if (!isValid) return;
    final mono = _clock.elapsedMilliseconds;
    final wall = DateTime.now().millisecondsSinceEpoch;
    final sent = _sent;
    if (sent != null && mono - sent.mono < 30000 && wall - sent.wall < 30000) return;
    if (!force && _lastRequest != null && mono - _lastRequest! < 25000) return;
    final request = (id: '${++_sequence}', mono: mono, wall: wall);
    _sent = request;
    if (_request({'connectionId': connectionId, 'requestId': request.id, 'ticket': _ticket})) {
      _lastRequest = mono;
    } else {
      _sent = null;
    }
  }

  /// Returns true only if this ack reauthorized this exact tunnel. Late acks
  /// cannot extend a lease from their arrival time.
  bool acknowledge(JsonMap ack) {
    if (!isValid || ack['connectionId'] != connectionId) return false;
    final sent = _sent;
    if (sent == null || sent.id != ack['requestId']) return false;
    if (_clock.elapsedMilliseconds - sent.mono >= 30000 || DateTime.now().millisecondsSinceEpoch - sent.wall >= 30000) {
      return false;
    }
    _sent = null;
    _ticket = ack['ticket']! as String;
    _confirmed = true;
    final leaseMs = ack['leaseMs']! as int;
    _deadlineMono = sent.mono + leaseMs;
    _deadlineWall = sent.wall + leaseMs;
    return true;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _sent = null;
  }
}
