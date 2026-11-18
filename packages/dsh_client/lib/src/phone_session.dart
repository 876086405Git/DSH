/// Data orchestration for the OHOS callback. The application owns the UI and
/// explicitly opens/closes this session when the local phone setting changes.
library;

import 'dart:async';

import 'connection.dart';
import 'errors.dart';
import 'phone_callback.dart';

abstract interface class DshPhoneNative {
  Future<DshPhoneOwner> attach();
  Future<void> retire(DshPhoneOwner owner);
  Future<DshPhoneResult> execute(DshPhoneClaim claim);
  Future<DshPhoneResult> continueHandoff(DshPhoneClaim claim);
  Future<bool?> cancel(DshPhoneClaim claim);
  Future<DshPhoneCheck> check(DshPhoneClaim claim);
}

final class DshPhoneCheck {
  const DshPhoneCheck({required this.pending, required this.foreground, required this.nowMs, required this.deadlineMs});
  factory DshPhoneCheck.fromNative(Object? raw) {
    if (raw is! Map ||
        raw.length != 4 ||
        raw['pending'] is! bool ||
        raw['foreground'] is! bool ||
        raw['nowMs'] is! int ||
        raw['deadlineMs'] is! int ||
        (raw['nowMs'] as int) < -1 ||
        (raw['deadlineMs'] as int) < 0 ||
        (raw['nowMs'] as int) > 9007199254740991 ||
        (raw['deadlineMs'] as int) > 9007199254740991) {
      throw const DshProtocolException('Invalid native phone check');
    }
    return DshPhoneCheck(
      pending: raw['pending'] as bool,
      foreground: raw['foreground'] as bool,
      nowMs: raw['nowMs'] as int,
      deadlineMs: raw['deadlineMs'] as int,
    );
  }
  final bool pending;
  final bool foreground;
  final int nowMs;
  final int deadlineMs;
}

enum DshPhonePhase { idle, executing, waitingUser, finished, failed, closed }

final class DshPhoneUpdate {
  const DshPhoneUpdate(this.phase, {this.request, this.result, this.accepted, this.code, this.foreground, this.nowMs});
  final DshPhonePhase phase;
  final DshPhoneRequest? request;
  final DshPhoneResult? result;
  final bool? accepted;
  final String? code;
  final bool? foreground;
  final int? nowMs;
}

/// One local owner, one sequential consumer. There is no automatic effect retry.
/// An uncertain HTTP acknowledgement is a failed session; reopening can receive
/// only unclaimed work, never re-execute the old request.
final class DshPhoneSession {
  DshPhoneSession._(this._native, this._client);

  static Future<DshPhoneSession> open(
    DshConnection authenticated, {
    required bool enabled,
    required DshPhoneNative native,
  }) async {
    if (!enabled) throw const DshPhoneException('disabled', 0);
    final owner = await native.attach();
    try {
      return DshPhoneSession._(native, DshPhoneClient(authenticated, owner));
    } catch (_) {
      await native.retire(owner);
      rethrow;
    }
  }

  final DshPhoneNative _native;
  final DshPhoneClient _client;
  final _updates = StreamController<DshPhoneUpdate>.broadcast(sync: true);
  DshPhoneUpdate _state = const DshPhoneUpdate(DshPhonePhase.idle);
  DshPhoneClaim? _active;
  Completer<void>? _handoff;
  Timer? _timer;
  bool _checking = false;
  bool _answering = false;
  bool _closed = false;
  Future<void>? _running;
  Future<void>? _closing;

  Stream<DshPhoneUpdate> get updates => _updates.stream;
  DshPhoneUpdate get state => _state;

  void _emit(DshPhoneUpdate value) {
    _state = value;
    if (!_updates.isClosed) _updates.add(value);
  }

  Future<void> run() => _running ??= _pump();

  Future<void> _pump() async {
    try {
      while (!_closed) {
        final request = await _client.next();
        if (_closed) break;
        if (request == null) continue;
        final claim = await _client.claim(request);
        if (_closed) break;
        _active = claim;
        if (request.isHandoff) {
          _handoff = Completer<void>();
          await _client.waiting(claim);
          if (_closed) break;
          _emit(DshPhoneUpdate(DshPhonePhase.waitingUser, request: request));
          if (_closed) break;
          _timer = Timer.periodic(const Duration(seconds: 1), (_) {
            unawaited(_checkHandoff(claim));
          });
          await _checkHandoff(claim);
          await _handoff?.future;
        } else {
          _emit(DshPhoneUpdate(DshPhonePhase.executing, request: request));
          if (_closed) break;
          final result = await _native.execute(claim);
          result.validateFor(request);
          if (_closed) break;
          final receipt = await _client.report(claim, result);
          _emit(DshPhoneUpdate(DshPhonePhase.finished, result: receipt.result, accepted: receipt.accepted));
        }
        _timer?.cancel();
        _timer = null;
        _active = null;
        _handoff = null;
      }
    } catch (error) {
      if (!_closed) _emit(DshPhoneUpdate(DshPhonePhase.failed, code: _code(error)));
    } finally {
      await close();
    }
  }

  String _code(Object error) => error is DshPhoneException
      ? error.code
      : error is DshProtocolException
      ? 'invalid_protocol'
      : 'callback_unavailable';

  DshPhoneClaim _current(String requestId, {bool handoff = false}) {
    final claim = _active;
    if (_closed ||
        claim == null ||
        claim.request.requestId != requestId ||
        handoff && (!claim.request.isHandoff || _handoff == null || _handoff!.isCompleted) ||
        _answering) {
      throw const DshPhoneException('stale_action', 0);
    }
    return claim;
  }

  void _releaseHandoff() {
    _timer?.cancel();
    _timer = null;
    final pending = _handoff;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  Future<void> _checkHandoff(DshPhoneClaim claim) async {
    if (_closed || _checking || _answering || !identical(_active, claim) || _handoff?.isCompleted != false) return;
    _checking = true;
    try {
      final check = await _native.check(claim).timeout(const Duration(seconds: 5));
      if (_closed || _answering || !identical(_active, claim) || _handoff?.isCompleted != false) return;
      if (!check.pending) {
        // Expiry, cancellation, or another terminal native state; no invented success.
        _emit(const DshPhoneUpdate(DshPhonePhase.finished, code: 'no_longer_pending'));
        _releaseHandoff();
      } else {
        if (check.deadlineMs != claim.request.deadlineMs || check.nowMs < 0 || check.nowMs >= check.deadlineMs) {
          throw const DshProtocolException('Invalid native phone deadline');
        }
        _emit(
          DshPhoneUpdate(
            DshPhonePhase.waitingUser,
            request: claim.request,
            foreground: check.foreground,
            nowMs: check.nowMs,
          ),
        );
      }
    } catch (error) {
      if (!_closed) {
        _emit(DshPhoneUpdate(DshPhonePhase.failed, code: _code(error)));
        await close();
      }
    } finally {
      _checking = false;
    }
  }

  /// Only this explicit current button can produce user_confirmed evidence.
  Future<DshPhoneReceipt> continueHandoff(String requestId) async {
    final claim = _current(requestId, handoff: true);
    _answering = true;
    var consumed = false;
    try {
      final result = await _native.continueHandoff(claim);
      consumed = result.dispatched;
      result.validateFor(claim.request);
      if (_closed) throw const DshClosedException('Phone callback closed');
      final receipt = await _client.report(claim, result);
      _emit(DshPhoneUpdate(DshPhonePhase.finished, result: receipt.result, accepted: receipt.accepted));
      _releaseHandoff();
      return receipt;
    } catch (error) {
      // A platform reply can disappear after consume. Keep the button locked
      // until the native authority proves it is still unconsumed and pending.
      DshPhoneCheck? retryable;
      if (!consumed && !_closed) {
        try {
          final check = await _native.check(claim).timeout(const Duration(seconds: 5));
          if (check.pending &&
              check.nowMs >= 0 &&
              check.nowMs < check.deadlineMs &&
              check.deadlineMs == claim.request.deadlineMs) {
            retryable = check;
          }
        } catch (_) {
          /* No proof that retrying confirmation remains valid. */
        }
      }
      if (retryable == null && !_closed) {
        _emit(DshPhoneUpdate(DshPhonePhase.failed, code: 'receipt_unconfirmed'));
        await close();
      } else if (retryable != null && !_closed) {
        _emit(
          DshPhoneUpdate(
            DshPhonePhase.waitingUser,
            request: claim.request,
            code: _code(error),
            foreground: retryable.foreground,
            nowMs: retryable.nowMs,
          ),
        );
      }
      rethrow;
    } finally {
      _answering = false;
      if (!_closed && _handoff?.isCompleted == false) unawaited(_checkHandoff(claim));
    }
  }

  /// Revoke locally first, then settle the Node waiter. A lost network reply
  /// cannot authorize a late native effect or erase a consumed action.
  Future<void> stop(String requestId) async {
    final claim = _current(requestId);
    _answering = true;
    Object? error;
    try {
      await _native.cancel(claim).timeout(const Duration(seconds: 5));
    } catch (value) {
      error = value;
    }
    try {
      await _client.cancel(claim.request);
    } catch (value) {
      error ??= value;
    }
    _answering = false;
    _releaseHandoff();
    if (error != null) {
      if (!_closed) _emit(DshPhoneUpdate(DshPhonePhase.failed, code: 'cancellation_unconfirmed'));
      await close();
      throw error;
    }
    if (!_closed) _emit(const DshPhoneUpdate(DshPhonePhase.finished, code: 'stop_requested'));
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _releaseHandoff();
    _client.close();
    String? problem;
    try {
      await _native.retire(_client.owner).timeout(const Duration(seconds: 5));
    } catch (_) {
      problem = 'owner_retire_unconfirmed';
    }
    _active = null;
    // Closing owns only the callback; a consumed SDK operation may still be
    // settling in native code and keeps its execution slot until it exits.
    _emit(DshPhoneUpdate(DshPhonePhase.closed, code: problem ?? _state.code));
    unawaited(_updates.close());
  }
}
