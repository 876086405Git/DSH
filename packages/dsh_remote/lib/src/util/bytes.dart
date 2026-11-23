// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
/// Byte, base64url and JSON helpers shared by the protocol layers.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

typedef JsonMap = Map<String, Object?>;

/// Unpadded base64url (RFC 4648 §5), the encoding of every key, handshake
/// and ciphertext on the ds-harness-remote wire.
String toBase64Url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Decodes base64url with or without padding. Throws [FormatException].
Uint8List fromBase64Url(String value) {
  final pad = (4 - value.length % 4) % 4;
  if (pad == 3) throw const FormatException('invalid base64url length');
  return base64Url.decode(value + ('=' * pad));
}

/// Canonical 32-byte X25519 public key encoding: exactly 43 characters.
final RegExp identityKeyPattern = RegExp(r'^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$');

const String _base64UrlAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
final RegExp _base64UrlPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// Non-empty unpadded base64url whose unused trailing bits are zero, so
/// every byte string has exactly one wire form (handshake data, Relay
/// ciphertext).
bool isCanonicalBase64Url(String value) {
  if (!_base64UrlPattern.hasMatch(value)) return false;
  final remainder = value.length % 4;
  if (remainder == 1) return false;
  if (remainder == 0) return true;
  final last = _base64UrlAlphabet.indexOf(value[value.length - 1]);
  return remainder == 2 ? last & 15 == 0 : last & 3 == 0;
}

bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List concatBytes(List<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  for (final part in parts) {
    out.add(part);
  }
  return out.takeBytes();
}

final Random _secure = Random.secure();

Uint8List randomBytes(int length) => Uint8List.fromList(List<int>.generate(length, (_) => _secure.nextInt(256)));

/// RFC 9562 UUIDv7 (time-ordered), used for device and message ids.
String uuidV7([DateTime? now]) {
  final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final bytes = randomBytes(16);
  for (var i = 0; i < 6; i++) {
    bytes[i] = (ms >> (8 * (5 - i))) & 0xff;
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

JsonMap? asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.map((key, v) => MapEntry(key.toString(), v));
  return null;
}

JsonMap asMapOrEmpty(Object? value) => asMap(value) ?? const {};

String? asString(Object? value) => value is String ? value : null;

int? asInt(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return null;
}

/// Largest integer JavaScript represents exactly (`Number.MAX_SAFE_INTEGER`).
const int maxSafeInteger = 9007199254740991;

bool isSafeInteger(Object? value) {
  final v = asInt(value);
  return v != null && v >= -maxSafeInteger && v <= maxSafeInteger;
}

Object? tryDecodeJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// [jsonDecode] for wire frames: also rejects an object that repeats a key,
/// including keys that only match once unescaped (`jsonDecode` keeps the
/// last one silently). Throws [FormatException].
Object? decodeWireJson(String text) {
  final value = jsonDecode(text);
  // The text is valid JSON now, so a string followed by `:` is a key.
  final objects = <Set<String>?>[];
  for (var i = 0; i < text.length; i++) {
    final char = text.codeUnitAt(i);
    if (char == 0x7b) {
      objects.add(<String>{});
    } else if (char == 0x5b) {
      objects.add(null);
    } else if (char == 0x7d || char == 0x5d) {
      objects.removeLast();
    } else if (char == 0x22) {
      final start = i;
      var escaped = false;
      for (i++; i < text.length; i++) {
        final c = text.codeUnitAt(i);
        if (c == 0x5c) {
          escaped = true;
          i++;
        } else if (c == 0x22) {
          break;
        }
      }
      var next = i + 1;
      while (next < text.length && _isJsonSpace(text.codeUnitAt(next))) {
        next++;
      }
      if (next == text.length || text.codeUnitAt(next) != 0x3a) continue;
      final key = escaped ? jsonDecode(text.substring(start, i + 1)) as String : text.substring(start + 1, i);
      if (!objects.last!.add(key)) throw const FormatException('Duplicate JSON field.');
    }
  }
  return value;
}

bool _isJsonSpace(int char) => char == 0x20 || char == 0x0a || char == 0x0d || char == 0x09;
