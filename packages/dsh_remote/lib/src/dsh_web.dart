import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'carrier/tunnel_carrier.dart' show RemoteHostSession;

/// A payload-free validation failure: never attach a grant or RPC response.
class RemoteDshWebException implements Exception {
  const RemoteDshWebException(this.code);
  final String code;

  @override
  String toString() => 'RemoteDshWebException($code)';
}

/// Trust comes from application configuration, never from a Host response.
/// Each configured parent authorizes exactly one independent tunnel subdomain.
bool isTrustedDshWebRoot(Uri uri, {Set<String> trustedTunnelDomains = const {'hostc.4ba.io'}}) {
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty ||
      uri.authority != uri.host ||
      uri.path != '/' ||
      uri.hasQuery ||
      uri.hasFragment) {
    return false;
  }
  for (final domain in trustedTunnelDomains) {
    if (!RegExp(r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]+$').hasMatch(domain)) continue;
    final suffix = '.$domain';
    if (!uri.host.endsWith(suffix)) continue;
    final label = uri.host.substring(0, uri.host.length - suffix.length);
    if (RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$').hasMatch(label)) return true;
  }
  return false;
}

/// Operation-local, single-use body for a native WebView top-level form POST.
class RemoteDshWebGrant {
  RemoteDshWebGrant._(this.url, this.expiresAt, this._grant, this._now);

  final Uri url;
  final int expiresAt;
  String? _grant;
  final DateTime Function() _now;

  Uri get exchangeUrl => url.resolve('/__remote/session');

  Uint8List takePostBody() {
    final grant = _grant;
    _grant = null;
    if (grant == null) throw const RemoteDshWebException('GRANT_CONSUMED');
    if (expiresAt <= _now().millisecondsSinceEpoch) throw const RemoteDshWebException('GRANT_EXPIRED');
    return Uint8List.fromList(utf8.encode(Uri(queryParameters: {'browserGrant': grant}).query));
  }

  void discard() => _grant = null;

  @override
  String toString() => 'RemoteDshWebGrant(redacted)';
}

class _SessionOperations {
  Future<void> tail = Future.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = tail.then((_) => operation());
    tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}

final _operations = Expando<_SessionOperations>();

/// Never reconnects or replays a request. Queues are shared by API instances
/// for one original Noise session, so close must finish before the next open.
class RemoteDshWeb {
  RemoteDshWeb(this.session, {Set<String> trustedTunnelDomains = const {'hostc.4ba.io'}, DateTime Function()? now})
    : trustedTunnelDomains = Set.unmodifiable(trustedTunnelDomains),
      _now = now ?? DateTime.now,
      _queue = _operations[session] ??= _SessionOperations();

  final RemoteHostSession session;
  final Set<String> trustedTunnelDomains;
  final DateTime Function() _now;
  final _SessionOperations _queue;

  bool get supported => !session.isClosed && session.capabilities.contains('dsh.web.v1');

  Future<RemoteDshWebGrant> open() => _queue.run(() async {
    if (!supported) throw RemoteDshWebException(session.isClosed ? 'CONNECTION_NOT_FOUND' : 'FEATURE_NOT_SUPPORTED');
    final result = await session.rpc.call(
      'dsh.web.open',
      const <String, Object?>{},
      timeout: const Duration(seconds: 25),
    );
    if (result is! Map) throw const RemoteDshWebException('INVALID_WEB_RESPONSE');
    final rawUrl = result['url'];
    final grant = result['browserGrant'];
    final expiresAt = result['expiresAt'];
    // Uri normalization can erase an empty port, so inspect raw authority too.
    final url = rawUrl is String && RegExp(r'^https://[A-Za-z0-9.-]+/$').hasMatch(rawUrl) ? Uri.tryParse(rawUrl) : null;
    if (url == null || !isTrustedDshWebRoot(url, trustedTunnelDomains: trustedTunnelDomains)) {
      throw const RemoteDshWebException('UNTRUSTED_WEB_URL');
    }
    if (grant is! String || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(grant) || expiresAt is! int) {
      throw const RemoteDshWebException('INVALID_WEB_RESPONSE');
    }
    if (expiresAt <= _now().millisecondsSinceEpoch) throw const RemoteDshWebException('GRANT_EXPIRED');
    return RemoteDshWebGrant._(url, expiresAt, grant, _now);
  });

  Future<bool> close() => _queue.run(() async {
    if (session.isClosed) return false;
    final result = await session.rpc.call(
      'dsh.web.close',
      const <String, Object?>{},
      timeout: const Duration(seconds: 10),
    );
    if (result is! Map || result['closed'] != true) throw const RemoteDshWebException('INVALID_WEB_RESPONSE');
    return true;
  });
}
