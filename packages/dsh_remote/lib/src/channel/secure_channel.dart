// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Client-side Noise IK channel over a [SecureHandshakeTransport].
library;

import 'dart:async';
import 'dart:typed_data';

import '../crypto/noise_ik.dart';
import '../protocol/control.dart';
import '../protocol/messages.dart';
import '../transport/transport.dart';

/// Why a secure channel ended.
class SecureChannelClosed {
  const SecureChannelClosed(this.code, this.message, {this.retryable = true});

  /// `SECURE_CHANNEL_FAILED` (decrypt, replay, reorder, framing),
  /// `PEER_IDENTITY_MISMATCH`, or the transport's code
  /// ([RemoteTransportClosed.code]).
  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => 'SecureChannelClosed($code): $message';
}

class SecureChannelException implements Exception {
  const SecureChannelException(this.code, this.message, {this.retryable = true});
  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => 'SecureChannelException($code): $message';
}

/// Authenticated, ordered, replay-protected message pipe to one Host.
///
/// * Handshake: client = initiator, both payloads empty, 10 s deadline; the
///   Host's static key must equal the pinned [hostIdentityKey].
/// * Sending: Remote message bytes (≤ 4 MiB) → DSHF fragments (> 48 KiB)
///   → one Noise message each, sent strictly in nonce order.
/// * Receiving: the Relay `counter` must equal the next Noise receive nonce;
///   any duplicate, gap, reorder, forgery or framing error closes the
///   channel (fail closed). There is no rekey (upstream roadmap).
class SecureChannel {
  SecureChannel._(this._transport, this._noise);

  static Future<SecureChannel> establish({
    required SecureHandshakeTransport transport,
    required String clientDeviceId,
    required String clientPrivateKey,
    required String clientPublicKey,
    required String hostDeviceId,
    required String hostIdentityKey,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final info = transport.info;
    if (info.localDeviceId != clientDeviceId || info.remoteDeviceId != hostDeviceId) {
      await transport.close();
      throw const SecureChannelException(
        'SECURE_CHANNEL_FAILED',
        'The relay connection is bound to an unexpected device.',
        retryable: false,
      );
    }
    final NoiseIkSession noise;
    try {
      noise = NoiseIkSession(
        role: NoiseRole.initiator,
        localPrivateKey: clientPrivateKey,
        localPublicKey: clientPublicKey,
        remotePublicKey: hostIdentityKey,
        prologue: createNoisePrologue(info.connectionId, hostDeviceId, clientDeviceId),
      );
    } on NoiseSessionError catch (error) {
      await transport.close();
      throw SecureChannelException(error.code, error.message, retryable: false);
    }
    final channel = SecureChannel._(transport, noise);
    await channel._handshake(timeout);
    return channel;
  }

  final SecureHandshakeTransport _transport;
  final NoiseIkSession _noise;
  final SecureMessageCodec _incoming = SecureMessageCodec();
  final SecureMessageCodec _outgoing = SecureMessageCodec();
  Completer<void>? _handshakeDone;
  void Function(Uint8List message)? _onMessage;
  void Function(SecureChannelClosed reason)? _onClosed;
  final List<Uint8List> _backlog = [];
  SecureChannelClosed? _closedReason;
  bool _closed = false;
  Future<void> _sendTail = Future.value();

  RemoteTransportMode get mode => _transport.mode;

  RemoteConnectionInfo get info => _transport.info;

  bool get isClosed => _closed;

  SecureChannelClosed? get closedReason => _closedReason;

  /// Checks Control liveness without replacing this channel or its RPCs.
  void checkControlHealth() {
    final transport = _transport;
    if (!_closed && transport is LeaseAwareTransport) transport.checkControlHealth();
  }

  Future<void> _handshake(Duration timeout) async {
    final done = _handshakeDone = Completer<void>();
    // listen may synchronously replay closure before the awaited send starts.
    done.future.ignore();
    _transport.listen(onData: _onData, onHandshake: _onHandshakeMessage, onClosed: _onTransportClosed);
    if (done.isCompleted) return done.future;
    try {
      await _transport.sendHandshake(1, _noise.writeHandshake());
      await done.future.timeout(timeout);
    } on TimeoutException {
      _fail(const SecureChannelClosed('SECURE_CHANNEL_FAILED', 'Noise IK handshake timed out.'));
      throw const SecureChannelException('SECURE_CHANNEL_FAILED', 'Noise IK handshake timed out.');
    } on SecureChannelException {
      rethrow;
    } on RemoteTransportException catch (error) {
      _fail(SecureChannelClosed(error.code, error.message, retryable: error.retryable));
      throw SecureChannelException(error.code, error.message, retryable: error.retryable);
    } on NoiseSessionError catch (error) {
      final reason = SecureChannelClosed(error.code, error.message, retryable: false);
      _fail(reason);
      throw SecureChannelException(error.code, error.message, retryable: false);
    }
  }

  void _onHandshakeMessage(int step, Uint8List data) {
    final done = _handshakeDone;
    if (done == null || done.isCompleted || _closed) return;
    try {
      if (step != 2) {
        throw const NoiseSessionError(
          'NOISE_HANDSHAKE_ORDER',
          'Noise IK responder sent an out-of-order handshake message.',
        );
      }
      _noise.readHandshake(data);
      if (!_noise.complete) {
        throw const NoiseSessionError('SECURE_CHANNEL_FAILED', 'Noise IK handshake did not complete.');
      }
      done.complete();
    } on NoiseSessionError catch (error) {
      final code = error.code == 'PEER_IDENTITY_MISMATCH' ? error.code : 'SECURE_CHANNEL_FAILED';
      final retryable = code != 'PEER_IDENTITY_MISMATCH';
      _fail(SecureChannelClosed(code, error.message, retryable: retryable));
      done.completeError(SecureChannelException(code, error.message, retryable: retryable));
    }
  }

  void _onData(Uint8List ciphertext, int? counter) {
    if (_closed) return;
    try {
      if (!_noise.complete) {
        throw const ProtocolError('Ciphertext arrived before the Noise handshake completed.');
      }
      if (counter != null && counter != _noise.receivingCounter) {
        throw const ProtocolError('Relay counter is duplicated or out of order.');
      }
      final message = _incoming.decode(_noise.decrypt(ciphertext));
      if (message == null) return;
      final handler = _onMessage;
      if (handler == null) {
        _backlog.add(message);
      } else {
        handler(message);
      }
    } on Object catch (error) {
      _fail(SecureChannelClosed('SECURE_CHANNEL_FAILED', 'Secure channel input rejected: $error'));
    }
  }

  void _onTransportClosed(RemoteTransportClosed reason) {
    final done = _handshakeDone;
    if (done != null && !done.isCompleted) {
      done.completeError(SecureChannelException(reason.code, reason.message, retryable: reason.retryable));
    }
    _fail(SecureChannelClosed(reason.code, reason.message, retryable: reason.retryable));
  }

  /// Registers the receiver. Messages decrypted earlier are delivered now.
  /// [onClosed] fires once (also immediately if already closed).
  void listen({
    required void Function(Uint8List message) onMessage,
    required void Function(SecureChannelClosed reason) onClosed,
  }) {
    _onMessage = onMessage;
    _onClosed = onClosed;
    final backlog = [..._backlog];
    _backlog.clear();
    backlog.forEach(onMessage);
    final reason = _closedReason;
    if (reason != null) onClosed(reason);
  }

  /// Sends one Remote message. Calls are serialized; a failure closes the
  /// channel. [canSend] may retire a queued message before its first fragment
  /// is encoded/encrypted. It is not checked again once sending has started.
  Future<void> send(Uint8List message, {bool Function()? canSend}) {
    final run = _sendTail.then<void>((_) {
      if (canSend?.call() == false) return null;
      return _sendNow(message);
    });
    _sendTail = run.catchError((Object _) {});
    return run;
  }

  Future<void> _sendNow(Uint8List message) async {
    if (_closed) {
      throw SecureChannelException(_closedReason?.code ?? 'SECURE_CHANNEL_FAILED', 'The secure channel is closed.');
    }
    try {
      for (final fragment in _outgoing.encode(message)) {
        final counter = _noise.sendingCounter;
        await _transport.send(_noise.encrypt(fragment), counter: counter);
      }
    } on ProtocolError catch (error) {
      // Oversized message: the channel is still intact, refuse just this one.
      if (error.code == 'FRAME_TOO_LARGE') {
        throw SecureChannelException('FRAME_TOO_LARGE', error.message, retryable: false);
      }
      rethrow;
    } on Object catch (error) {
      _fail(SecureChannelClosed('SECURE_CHANNEL_FAILED', 'Secure send failed: $error'));
      rethrow;
    }
  }

  void _fail(SecureChannelClosed reason) {
    if (_closed) return;
    _closed = true;
    _closedReason = reason;
    _noise.destroy();
    _incoming.reset();
    _outgoing.reset();
    unawaited(_transport.close());
    _onClosed?.call(reason);
  }

  /// Closes the channel before notifying receivers, retaining an optional
  /// local protocol failure instead of reporting it as a client shutdown.
  Future<void> close({SecureChannelClosed? reason}) async {
    if (_closed) return;
    _fail(
      reason ?? const SecureChannelClosed('CLIENT_CLOSED', 'The client closed the secure channel.', retryable: false),
    );
  }
}
