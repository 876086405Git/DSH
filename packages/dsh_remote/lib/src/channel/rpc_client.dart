// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Remote RPC correlation over the secure channel.
library;

import 'dart:async';
import 'dart:typed_data';

import '../protocol/messages.dart';
import '../util/bytes.dart';
import 'secure_channel.dart';

/// Maximum in-flight RPCs per connection (protocol limit).
const int maxPendingRpc = 128;

/// A Remote RPC failed. Host refusals carry the Host's `rpc.error` code
/// (`METHOD_NOT_ALLOWED`, `RPC_TIMEOUT`, `RESPONSE_TOO_LARGE`,
/// `RATE_LIMITED`, `TERMINAL_DISABLED`, ...); local failures use
/// `RPC_TIMEOUT` ([isLocal]) or `TRANSPORT_CLOSED` / `CLIENT_CLOSED`.
class RemoteRpcException implements Exception {
  const RemoteRpcException(this.code, this.message, {this.details, this.retryable = false, this.isLocal = false});

  final String code;
  final String message;
  final Object? details;
  final bool retryable;

  /// Raised on this side (deadline, channel loss), not by the Host.
  final bool isLocal;

  bool get isTransportClosed => code == 'TRANSPORT_CLOSED' || code == 'CLIENT_CLOSED';

  @override
  String toString() => 'RemoteRpcException($code${isLocal ? ', local' : ''}): $message';
}

/// `event` message payload: `{event, data, seq?, sessionId?}`.
class RemoteEvent {
  const RemoteEvent(this.event, this.data, {this.seq});

  final String event;
  final Object? data;
  final int? seq;
}

class _Pending {
  _Pending(this.method, this.completer, this.timer);
  final String method;
  final Completer<Object?> completer;
  final Timer timer;
}

/// Request/response correlation by message id, events fan-out, deadlines.
/// Every request gets exactly one outcome; late responses are dropped.
class RemoteRpcClient {
  RemoteRpcClient(this._channel, {this.defaultTimeout = const Duration(seconds: 35)}) {
    _channel.listen(onMessage: _onMessage, onClosed: _onClosed);
  }

  final SecureChannel _channel;
  final Duration defaultTimeout;
  final Map<String, _Pending> _pending = {};
  final StreamController<RemoteEvent> _events = StreamController.broadcast(sync: true);
  final Completer<SecureChannelClosed> _done = Completer();
  int _eventDispatchDepth = 0;
  final Stopwatch _sinceInbound = Stopwatch()..start();

  /// Events in arrival order (synchronous broadcast: subscribe before the
  /// RPC that triggers them).
  Stream<RemoteEvent> get events => _events.stream;

  /// Completes once when the channel is gone.
  Future<SecureChannelClosed> get done => _done.future;

  bool get isClosed => _done.isCompleted;

  SecureChannel get channel => _channel;

  /// Time since the Host last sent anything (a reply, event or stream frame).
  Duration get sinceInbound => _sinceInbound.elapsed;

  Future<Object?> call(String method, Object? params, {Duration? timeout}) {
    if (_done.isCompleted) {
      return Future.error(
        RemoteRpcException('TRANSPORT_CLOSED', 'RPC $method: the remote channel is closed.', isLocal: true),
      );
    }
    if (_pending.length >= maxPendingRpc) {
      return Future.error(
        RemoteRpcException('RATE_LIMITED', 'Too many pending remote RPCs.', retryable: true, isLocal: true),
      );
    }
    final request = RemoteMessage.rpcRequest(method, params);
    final completer = Completer<Object?>();
    final deadline = timeout ?? defaultTimeout;
    final timer = Timer(deadline, () {
      _reject(
        request.id,
        RemoteRpcException(
          'RPC_TIMEOUT',
          'RPC $method timed out after ${deadline.inMilliseconds} ms.',
          retryable: true,
          isLocal: true,
        ),
      );
    });
    _pending[request.id] = _Pending(method, completer, timer);
    final Uint8List encoded;
    try {
      encoded = request.encode();
    } on Object {
      // No Future was returned to the caller: retire only this reservation.
      _take(request.id);
      rethrow;
    }
    // Do not await the write: a deadline or close must settle the RPC even
    // when the send never completes.
    // An earlier send can keep this request queued beyond its deadline.
    // Retire it before encoding its first Noise fragment, never between them.
    _channel.send(encoded, canSend: () => _pending.containsKey(request.id)).catchError((Object error) {
      _reject(
        request.id,
        error is SecureChannelException && error.code == 'FRAME_TOO_LARGE'
            ? RemoteRpcException('FRAME_TOO_LARGE', error.message, isLocal: true)
            : RemoteRpcException('TRANSPORT_CLOSED', 'RPC $method send failed: $error', retryable: true, isLocal: true),
      );
    });
    return completer.future;
  }

  void _onMessage(Uint8List bytes) {
    _sinceInbound.reset();
    final RemoteMessage message;
    try {
      message = RemoteMessage.decode(bytes);
    } on Object catch (error) {
      // Fail closed on malformed plaintext.
      final reason = SecureChannelClosed('SECURE_CHANNEL_FAILED', 'Invalid Remote message: $error');
      unawaited(_channel.close(reason: reason));
      _onClosed(reason);
      return;
    }
    switch (message.type) {
      case 'rpc.response':
        final payload = asMap(message.payload);
        final requestId = asString(payload?['requestId']);
        if (requestId == null) return;
        final pending = _take(requestId);
        pending?.completer.complete(payload!['result']);
      case 'rpc.error':
        final RpcErrorPayload error;
        try {
          error = RpcErrorPayload.parse(message.payload);
        } on Object {
          return;
        }
        _take(error.requestId)?.completer.completeError(
          RemoteRpcException(error.code, error.message, details: error.details, retryable: error.retryable ?? false),
        );
      case 'event':
        final payload = asMap(message.payload);
        final name = asString(payload?['event']);
        if (name == null || _events.isClosed) return;
        _eventDispatchDepth++;
        try {
          _events.add(RemoteEvent(name, payload!['data'], seq: asInt(payload['seq'])));
        } finally {
          _eventDispatchDepth--;
          if (_eventDispatchDepth == 0 && _done.isCompleted) unawaited(_events.close());
        }
      default:
        // rpc.request from the Host is not part of the client contract.
        break;
    }
  }

  _Pending? _take(String requestId) {
    final pending = _pending.remove(requestId);
    pending?.timer.cancel();
    return pending;
  }

  void _reject(String requestId, RemoteRpcException error) {
    final pending = _take(requestId);
    if (pending != null && !pending.completer.isCompleted) pending.completer.completeError(error);
  }

  void _onClosed(SecureChannelClosed reason) {
    if (_done.isCompleted) return;
    _done.complete(reason);
    final code = reason.code == 'CLIENT_CLOSED' ? 'CLIENT_CLOSED' : 'TRANSPORT_CLOSED';
    for (final id in [..._pending.keys]) {
      final pending = _pending[id]!;
      _reject(
        id,
        RemoteRpcException(
          code,
          'RPC ${pending.method} ended: ${reason.message}',
          retryable: reason.retryable,
          isLocal: true,
        ),
      );
    }
    // Synchronous listeners may close the RPC while an event is firing.
    // The outermost dispatch closes the stream as soon as add returns.
    if (_eventDispatchDepth == 0) unawaited(_events.close());
  }

  Future<void> close() async {
    await _channel.close();
    _onClosed(const SecureChannelClosed('CLIENT_CLOSED', 'The client closed the remote connection.', retryable: false));
  }
}
