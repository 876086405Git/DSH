// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Secure-channel plaintext: Remote messages and DSHF fragments.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../util/bytes.dart';
import 'control.dart';

/// Remote messages above this size are split into DSHF fragments before
/// Noise encryption.
const int secureFragmentChunkBytes = 48 * 1024;

/// Largest reassembled Remote message.
const int maxSecureMessageBytes = 4 * 1024 * 1024;

const int _fragmentHeaderBytes = 17;
const int _fragmentVersion = 1;
const int _maxInFlightMessages = 8;
const List<int> _fragmentMagic = [0x44, 0x53, 0x48, 0x46]; // DSHF

const List<String> remoteMessageTypes = ['rpc.request', 'rpc.response', 'rpc.error', 'event'];

/// `{v: 1, id, type, timestamp, payload}`, only ever inside the Noise
/// channel.
class RemoteMessage {
  RemoteMessage(this.type, this.payload, {String? id, int? timestamp})
    : id = id ?? uuidV7(),
      timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;

  factory RemoteMessage.rpcRequest(String method, Object? params, {String? id}) =>
      RemoteMessage('rpc.request', {'method': method, 'params': params}, id: id);

  final String id;
  final String type;
  final int timestamp;
  final Object? payload;

  JsonMap toJson() => {'v': protocolVersion, 'id': id, 'type': type, 'timestamp': timestamp, 'payload': payload};

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// Strict decode (fail closed): valid UTF-8 JSON without duplicate keys,
  /// v1, known type.
  static RemoteMessage decode(List<int> bytes) {
    final Object? json;
    try {
      json = decodeWireJson(utf8.decode(bytes));
    } on FormatException {
      throw const ProtocolError('Remote message is not valid UTF-8 JSON.');
    }
    final map = asMap(json);
    if (map == null) throw const ProtocolError('Remote message is not a JSON object.');
    if (map['v'] != protocolVersion) {
      throw const ProtocolError('Unsupported Remote message version.', 'UNSUPPORTED_VERSION');
    }
    final id = map['id'];
    final type = map['type'];
    final timestamp = asInt(map['timestamp']);
    if (id is! String || id.isEmpty) throw const ProtocolError('Remote message id is required.');
    if (type is! String || !remoteMessageTypes.contains(type)) {
      throw const ProtocolError('Unknown Remote message type.');
    }
    if (timestamp == null || timestamp <= 0 || timestamp > maxSafeInteger) {
      throw const ProtocolError('Remote message timestamp is invalid.');
    }
    return RemoteMessage(type, map['payload'], id: id, timestamp: timestamp);
  }
}

/// `rpc.error` payload.
class RpcErrorPayload {
  const RpcErrorPayload(this.requestId, this.code, this.message, {this.retryable, this.details});

  final String requestId;
  final String code;
  final String message;
  final bool? retryable;
  final Object? details;

  static RpcErrorPayload parse(Object? input) {
    final map = asMap(input);
    if (map == null) throw const ProtocolError('rpc.error payload must be an object.');
    final requestId = map['requestId'];
    final code = map['code'];
    final message = map['message'];
    if (requestId is! String || requestId.isEmpty) {
      throw const ProtocolError('rpc.error requestId is required.');
    }
    if (code is! String || code.isEmpty) throw const ProtocolError('rpc.error code is required.');
    if (message is! String || message.isEmpty) {
      throw const ProtocolError('rpc.error message is required.');
    }
    if (map.containsKey('retryable') && map['retryable'] is! bool) {
      throw const ProtocolError('rpc.error retryable must be a boolean.');
    }
    return RpcErrorPayload(requestId, code, message, retryable: map['retryable'] as bool?, details: map['details']);
  }
}

class _Assembly {
  _Assembly(this.total, this.totalBytes);
  final int total;
  final int totalBytes;
  final BytesBuilder bytes = BytesBuilder(copy: false);
  int received = 0;
}

/// Splits plaintext before Noise encryption and reassembles it after
/// decryption. Noise caps one transport message at 65535 bytes, so messages
/// above 48 KiB travel as DSHF fragments:
///
/// `DSHF` | version u8 (1) | messageId u32 | index u16 | total u16 |
/// totalBytes u32 | ≤ 48 KiB chunk, all big-endian. Fragments of one message
/// arrive contiguous and in order within one authenticated channel; any
/// duplicate, gap, length mismatch or over-limit size throws (close the
/// channel).
class SecureMessageCodec {
  int _nextMessageId = 1;
  final Map<int, _Assembly> _assemblies = {};

  List<Uint8List> encode(Uint8List message) {
    if (message.length > maxSecureMessageBytes) {
      throw const ProtocolError('Secure message exceeds the reassembly limit.', 'FRAME_TOO_LARGE');
    }
    if (message.length <= secureFragmentChunkBytes) return [message];
    final messageId = _nextMessageId;
    _nextMessageId = messageId == 0xffffffff ? 1 : messageId + 1;
    final total = (message.length + secureFragmentChunkBytes - 1) ~/ secureFragmentChunkBytes;
    final frames = <Uint8List>[];
    for (var index = 0; index < total; index++) {
      final start = index * secureFragmentChunkBytes;
      final end = start + secureFragmentChunkBytes < message.length ? start + secureFragmentChunkBytes : message.length;
      final frame = Uint8List(_fragmentHeaderBytes + end - start);
      frame.setRange(0, 4, _fragmentMagic);
      final view = ByteData.sublistView(frame);
      view.setUint8(4, _fragmentVersion);
      view.setUint32(5, messageId);
      view.setUint16(9, index);
      view.setUint16(11, total);
      view.setUint32(13, message.length);
      frame.setRange(_fragmentHeaderBytes, frame.length, message, start);
      frames.add(frame);
    }
    return frames;
  }

  /// Returns the complete message, or `null` while a fragmented message is
  /// still incomplete.
  Uint8List? decode(Uint8List frame) {
    if (!_isFragment(frame)) return frame;
    if (frame.length < _fragmentHeaderBytes || frame[4] != _fragmentVersion) {
      throw const ProtocolError('Secure fragment header is invalid.');
    }
    final view = ByteData.sublistView(frame);
    final messageId = view.getUint32(5);
    final index = view.getUint16(9);
    final total = view.getUint16(11);
    final totalBytes = view.getUint32(13);
    if (messageId == 0 ||
        total < 2 ||
        index >= total ||
        totalBytes <= secureFragmentChunkBytes ||
        totalBytes > maxSecureMessageBytes ||
        total != (totalBytes + secureFragmentChunkBytes - 1) ~/ secureFragmentChunkBytes) {
      throw const ProtocolError('Secure fragment metadata is invalid.');
    }
    final remaining = totalBytes - index * secureFragmentChunkBytes;
    final expected = remaining < secureFragmentChunkBytes ? remaining : secureFragmentChunkBytes;
    final chunkLength = frame.length - _fragmentHeaderBytes;
    if (chunkLength != expected) throw const ProtocolError('Secure fragment length is invalid.');

    var assembly = _assemblies[messageId];
    if (assembly == null) {
      if (index != 0 || _assemblies.length >= _maxInFlightMessages) {
        throw const ProtocolError('Secure fragment sequence is invalid.');
      }
      assembly = _assemblies[messageId] = _Assembly(total, totalBytes);
    }
    final chunksSoFar = assembly.received == 0
        ? 0
        : (assembly.received + secureFragmentChunkBytes - 1) ~/ secureFragmentChunkBytes;
    if (assembly.total != total || assembly.totalBytes != totalBytes || index != chunksSoFar) {
      _assemblies.remove(messageId);
      throw const ProtocolError('Secure fragment sequence is invalid.');
    }
    assembly.bytes.add(Uint8List.sublistView(frame, _fragmentHeaderBytes));
    assembly.received += chunkLength;
    if (index + 1 < total) return null;
    _assemblies.remove(messageId);
    if (assembly.received != totalBytes) {
      throw const ProtocolError('Secure message length is invalid.');
    }
    return assembly.bytes.takeBytes();
  }

  void reset() {
    _nextMessageId = 1;
    _assemblies.clear();
  }

  static bool _isFragment(Uint8List frame) {
    if (frame.length < _fragmentMagic.length) return false;
    for (var i = 0; i < _fragmentMagic.length; i++) {
      if (frame[i] != _fragmentMagic[i]) return false;
    }
    return true;
  }
}
