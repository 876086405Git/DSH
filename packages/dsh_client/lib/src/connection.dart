/// Physical carrier for one `dsh web` Host: launch-token login, the
/// authority-bound session cookie, plain HTTP exchanges and the WebSocket
/// upgrade, all sent with the right `Host` header and never an `Origin`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'background_session_read.dart';
import 'errors.dart';
import 'json.dart';
import 'models.dart' show SessionSummary;

/// Signed browser-session cookie minted by `GET /?token=<launch token>`.
///
/// It is bound to the exact `host:port` authority the login used and stays
/// valid for 30 days by default, across `dsh web` restarts that keep the same
/// `DSH_HOME` (the signing secret lives in `$DSH_HOME/.credentials.yaml`).
/// The launch token itself changes every process start. Persist the cookie
/// (it is a bearer credential: use secure storage) and re-login only on 401.
class DshCookie {
  const DshCookie({required this.name, required this.value, required this.authority, this.expiresAt});

  factory DshCookie.fromJson(Map<String, Object?> json) => DshCookie(
    name: asString(json['name']) ?? '',
    value: asString(json['value']) ?? '',
    authority: asString(json['authority']) ?? '',
    expiresAt: asEpochMs(json['expiresAt']),
  );

  /// `dsh-auth-<base64url(sha256(authority))>`.
  final String name;

  /// `v1.<payload>.<signature>`; opaque to the client.
  final String value;

  /// `host:port` the cookie is bound to; requests must send this `Host`.
  final String authority;
  final DateTime? expiresAt;

  String get header => '$name=$value';

  bool isExpiredAt(DateTime now) => expiresAt != null && !now.isBefore(expiresAt!);

  Map<String, Object?> toJson() => {
    'name': name,
    'value': value,
    'authority': authority,
    if (expiresAt != null) 'expiresAt': expiresAt!.millisecondsSinceEpoch,
  };

  @override
  String toString() => 'DshCookie($name for $authority, expires $expiresAt)';
}

/// The URL `dsh web` prints on stdout once it is ready, e.g.
/// `dsh web: http://127.0.0.1:3080/?token=...`.
class DshLaunchUrl {
  const DshLaunchUrl(this.baseUri, this.token);

  final Uri baseUri;
  final String token;

  /// Accepts the whole `dsh web: <url>` line or a bare URL; `null` when no
  /// URL with a `token` query parameter is present.
  static DshLaunchUrl? tryParse(String text) {
    final match = RegExp(r'https?://\S+').firstMatch(text);
    if (match == null) return null;
    final uri = Uri.tryParse(match.group(0)!);
    final token = uri?.queryParameters['token'];
    if (uri == null || token == null || token.isEmpty) return null;
    final base = uri.replace(query: '', fragment: '');
    return DshLaunchUrl(
      Uri(scheme: base.scheme, host: base.host, port: base.port, path: base.path == '/' ? '' : base.path),
      token,
    );
  }
}

/// One traced wire exchange; used by `bin/probe.dart --record`.
class DshTraceEntry {
  DshTraceEntry(this.direction, this.channel, this.data) : time = DateTime.now();

  final DateTime time;

  /// `out` (client to Host) or `in`.
  final String direction;

  /// `rpc`, `mux`, `http`.
  final String channel;
  final Object? data;

  Map<String, Object?> toJson() => {
    't': time.millisecondsSinceEpoch,
    'dir': direction,
    'channel': channel,
    'data': data,
  };
}

typedef DshTracer = void Function(DshTraceEntry entry);

/// Raw HTTP response with the body fully read.
class DshHttpResponse {
  const DshHttpResponse(
    this.statusCode,
    this.contentType,
    this.body, {
    this.setCookies = const [],
    this.contentTypeParameters = const {},
  });

  final int statusCode;

  /// Raw `Set-Cookie` header values.
  final List<String> setCookies;

  /// Lower-cased media type without parameters (`application/json`).
  final String contentType;

  /// The media type's parameters (`boundary` of a multipart body).
  final Map<String, String?> contentTypeParameters;
  final Uint8List body;

  String get text => utf8.decode(body, allowMalformed: true);
}

/// Reachability of the Host as seen by [DshConnection.checkHealth].
enum DshHealth {
  /// `GET /` with the cookie returned 200: the Host is up and the cookie works.
  ok,

  /// The Host answered 401/403: up, but log in again (or fix `Host`).
  unauthorized,

  /// Nothing answered (connection refused, DNS, timeout).
  unreachable,
}

/// HTTP + WebSocket carrier to one Host.
///
/// The Host fence requires a loopback or `--trusted-host` `Host` header,
/// refuses any `Origin` that differs from `Host` and any
/// `sec-fetch-site: cross-site`. `dart:io` sends no `Origin` by default; this
/// class never adds one. Use [hostHeader] when the socket goes through a
/// tunnel whose public name the Host does not trust: the Host only checks the
/// header, so a tunnel that preserves it can present `127.0.0.1:<port>`.
class DshConnection {
  DshConnection(
    Uri baseUri, {
    this.hostHeader,
    this.cookie,
    HttpClient? httpClient,
    this.connectTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 120),
    DshTracer? tracer,
  }) : baseUri = _normalizeBase(baseUri),
       _http = httpClient ?? HttpClient(),
       _ownsClient = httpClient == null,
       _usesDefaultHttp = httpClient == null && HttpOverrides.current == null,
       _tracer = tracer {
    if (_ownsClient) {
      _http
        ..connectionTimeout = connectTimeout
        ..idleTimeout = const Duration(seconds: 15)
        ..autoUncompress = true;
    }
  }

  /// `http://127.0.0.1:3080` (plus an optional mount path, no trailing `/`).
  final Uri baseUri;

  /// Overrides the `Host` header (`host:port`); defaults to [baseUri]'s authority.
  final String? hostHeader;
  final Duration connectTimeout;
  final Duration requestTimeout;
  DshTracer? _tracer;
  DshTracer? get tracer => _tracer;
  set tracer(DshTracer? value) {
    if (!identical(value, _tracer)) {
      _backgroundReads?.close();
      _backgroundReads = null;
    }
    _tracer = value;
  }

  BackgroundListReads? _backgroundReads;
  bool _closed = false;

  /// True only for the unmodified stock transport without a tracer or custom
  /// HttpClient/HttpOverrides. Custom behavior continues through postJson.
  bool get canReadSessionsInBackground =>
      runtimeType == DshConnection && _usesDefaultHttp && !_closed && tracer == null && HttpOverrides.current == null;

  /// Explicit opt-in used by the HTTP client. A worker owns this read's entire
  /// HTTP chain and decode; closing this connection retires its pending reads.
  Future<List<SessionSummary>> readSessionsInBackground() async =>
      (await readListInBackground(BackgroundListKind.sessions)) as List<SessionSummary>;

  /// Internal typed-list dispatch. Only the fixed read-only operations in
  /// [BackgroundListKind] can use the worker; mutations keep the normal RPC.
  Future<Object?> readListInBackground(BackgroundListKind kind, {List<String> credentialRefs = const []}) {
    if (!canReadSessionsInBackground) throw StateError('background session reads are unavailable');
    return (_backgroundReads ??= BackgroundListReads()).read(
      BackgroundListRequest(
        uri: resolve('/api/${kind.endpoint}'),
        kind: kind,
        rpcId: uuidV4(),
        connectTimeout: connectTimeout,
        requestTimeout: requestTimeout,
        hostHeader: hostHeader,
        cookieHeader: cookie?.header,
        credentialRefs: List.unmodifiable(credentialRefs),
      ),
    );
  }

  /// Current session cookie; set by [login] or restored from storage.
  DshCookie? cookie;

  final HttpClient _http;
  final bool _ownsClient;
  final bool _usesDefaultHttp;

  /// Authority the Host sees, which is also what the cookie is bound to.
  String get authority => hostHeader ?? _authorityOf(baseUri);

  bool get hasCookie => cookie != null;

  Uri resolve(String path, [Map<String, String>? query]) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return baseUri.replace(
      path: '${baseUri.path}$normalized',
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  /// The address to dial for [url] when it names this engine, by the address
  /// this connection dials or the authority the engine knows itself by; null
  /// for anything else. Only these may carry [cookie]. The result is always on
  /// [baseUri], never the address in [url], and keeps [url]'s query as written.
  /// Root-relative API paths inside this mount also name the engine; other
  /// relative paths retain their workspace-file meaning in Markdown.
  Uri? ownUri(String url) {
    var uri = Uri.tryParse(url);
    if (uri == null || uri.userInfo.isNotEmpty) return null;
    if (!uri.hasScheme && !uri.hasAuthority) {
      uri = uri.normalizePath();
      if (!uri.path.startsWith('${baseUri.path}/api/')) return null;
    } else {
      if (uri.scheme != baseUri.scheme) return null;
      final named = _authorityOf(uri);
      if (named != authority && named != _authorityOf(baseUri)) return null;
    }
    if (!uri.path.startsWith('${baseUri.path}/')) return null;
    return baseUri.replace(path: uri.path, query: uri.hasQuery ? uri.query : null);
  }

  Uri webSocketUri(String path) {
    final http = resolve(path);
    return http.replace(scheme: http.scheme == 'https' ? 'wss' : 'ws');
  }

  /// Exchanges the launch token for the session cookie.
  ///
  /// The token is only accepted on `GET /` (a single `token` parameter); the
  /// Host answers `303 Location: ./` with
  /// `Set-Cookie: dsh-auth-...=v1....; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict`.
  /// A wrong token, a token from another process, or a token sent on another
  /// path answers 401.
  Future<DshCookie> login(String token) async {
    final uri = resolve('/', {'token': token});
    _trace('out', 'http', {'method': 'GET', 'path': '/?token=<redacted>'});
    final response = await _exchange('GET', uri, followRedirects: false);
    _trace('in', 'http', {'status': response.statusCode, 'path': '/'});
    if (response.statusCode == 401) {
      throw const DshHttpException(401, 'launch token rejected (stale token, other dsh process, or wrong host:port)');
    }
    if (response.statusCode != 303 && response.statusCode != 302) {
      throw DshHttpException(response.statusCode, 'unexpected login response', body: response.text);
    }
    final minted = response.setCookies
        .map((raw) => _parseSetCookie(raw, authority))
        .whereType<DshCookie>()
        .where((c) => c.name.startsWith('dsh-auth-'))
        .firstOrNull;
    if (minted == null) {
      throw const DshProtocolException('login redirect carried no dsh-auth cookie');
    }
    cookie = minted;
    return minted;
  }

  /// Cheap readiness probe: `GET /` with the cookie. `dsh web` prints its URL
  /// line only after startup completes, and the WebSocket route is mounted
  /// only after application readiness, so 200 here plus a `ready` frame on
  /// `$events` mean the Host is fully usable. There is no dedicated health
  /// endpoint in 0.2.0-rc.2.
  Future<DshHealth> checkHealth({Duration? timeout}) async {
    try {
      final response = await _exchange('GET', resolve('/'), followRedirects: false, timeout: timeout ?? connectTimeout);
      if (response.statusCode == 200) return DshHealth.ok;
      if (response.statusCode == 401 || response.statusCode == 403) {
        return DshHealth.unauthorized;
      }
      return DshHealth.unreachable;
    } on DshTransportException {
      return DshHealth.unreachable;
    }
  }

  /// POSTs one JSON body and returns the raw response (any status).
  Future<DshHttpResponse> postJson(String path, Object? body, {Duration? timeout}) {
    return _exchange(
      'POST',
      resolve(path),
      body: utf8.encode(jsonEncode(body)),
      contentType: 'application/json',
      timeout: timeout,
    );
  }

  /// POSTs raw bytes (used for `session/uploadFileBinary`).
  Future<DshHttpResponse> postBytes(
    String path,
    List<int> bytes, {
    Map<String, String>? query,
    String contentType = 'application/octet-stream',
    Duration? timeout,
    bool followRedirects = true,
    int? maxResponseBytes,
  }) {
    return _exchange(
      'POST',
      resolve(path, query),
      body: bytes,
      contentType: contentType,
      timeout: timeout,
      followRedirects: followRedirects,
      maxResponseBytes: maxResponseBytes,
    );
  }

  /// Authenticated GET returning the raw response (any status), e.g. the
  /// Host's `/api/file?path=…` file route. [headers] adds request headers
  /// (`if-none-match`). Optional limits keep this connection's custom client
  /// and proxy/TLS policy; existing callers retain the same defaults.
  Future<DshHttpResponse> get(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
    int? maxResponseBytes,
  }) {
    return _exchange(
      'GET',
      resolve(path, query),
      headers: headers,
      timeout: timeout,
      followRedirects: followRedirects,
      maxResponseBytes: maxResponseBytes,
    );
  }

  /// A bounded authenticated GET for media: no redirects (not even same
  /// origin), at most [maxBytes] of body, one [timeout] for the whole read.
  /// It runs on a client of its own, closed (with its socket) as soon as the
  /// read ends or fails, so nothing half-read goes back to a pool; [get] is
  /// unchanged. Throws [DshHttpException] for a redirect,
  /// [DshProtocolException] past [maxBytes] and [DshTransportException] for a
  /// timeout or a failed socket. When [autoUncompress] is enabled, the
  /// streamed byte budget applies after decompression. The default preserves
  /// the original binary-media behavior.
  Future<DshHttpResponse> getBounded(
    String path, {
    Map<String, String>? query,
    required int maxBytes,
    bool autoUncompress = false,
    Duration timeout = const Duration(seconds: 30),
  }) => _getBounded(resolve(path, query), maxBytes: maxBytes, autoUncompress: autoUncompress, timeout: timeout);

  /// [getBounded] for a whole [url] that [ownUri] accepts. Anything else is
  /// refused here, before a socket opens, so the cookie can't leave this engine.
  Future<DshHttpResponse> getBoundedOwn(
    String url, {
    required int maxBytes,
    bool autoUncompress = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final uri = ownUri(url);
    if (uri == null) throw ArgumentError.value(url, 'url', 'not this engine');
    return _getBounded(uri, maxBytes: maxBytes, autoUncompress: autoUncompress, timeout: timeout);
  }

  Future<DshHttpResponse> _getBounded(
    Uri uri, {
    required int maxBytes,
    required bool autoUncompress,
    required Duration timeout,
  }) async {
    if (maxBytes < 1) throw ArgumentError.value(maxBytes, 'maxBytes');
    final http = HttpClient()
      ..connectionTimeout = connectTimeout
      ..autoUncompress = autoUncompress;
    var timedOut = false;
    // One deadline for connecting, headers and body: closing the client
    // fails whichever await is pending.
    final deadline = Timer(timeout, () {
      timedOut = true;
      http.close(force: true);
    });
    try {
      final req = await http.getUrl(uri);
      req.followRedirects = false;
      req.persistentConnection = false;
      _applyHost(req.headers);
      if (cookie != null) req.headers.set(HttpHeaders.cookieHeader, cookie!.header);
      final response = await req.close();
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw DshHttpException(response.statusCode, 'GET ${uri.path}: redirects are not followed');
      }
      if (response.contentLength > maxBytes) {
        throw DshProtocolException('GET ${uri.path}: body exceeds $maxBytes bytes');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (builder.length + chunk.length > maxBytes) {
          throw DshProtocolException('GET ${uri.path}: body exceeds $maxBytes bytes');
        }
        builder.add(chunk);
      }
      if (timedOut) throw TimeoutException('read timed out', timeout);
      final type = response.headers.contentType;
      return DshHttpResponse(
        response.statusCode,
        type == null ? '' : '${type.primaryType}/${type.subType}'.toLowerCase(),
        builder.takeBytes(),
        contentTypeParameters: type?.parameters ?? const {},
      );
    } on DshException {
      rethrow;
    } catch (error) {
      if (timedOut || error is TimeoutException) throw DshTransportException('GET ${uri.path} timed out', error);
      if (error is SocketException) throw DshTransportException('GET ${uri.path} failed: ${error.message}', error);
      if (error is HttpException) throw DshTransportException('GET ${uri.path} failed: ${error.message}', error);
      if (error is HandshakeException) throw DshTransportException('TLS handshake failed: ${error.message}', error);
      rethrow;
    } finally {
      deadline.cancel();
      http.close(force: true);
    }
  }

  /// Opens the authenticated WebSocket (`/api/remote.mux`).
  ///
  /// A missing/expired cookie fails the upgrade with HTTP 401 and a fence
  /// failure with 403; both surface as [DshHttpException].
  Future<WebSocket> connectWebSocket(String path, {Duration? timeout}) async {
    final headers = <String, Object>{if (cookie != null) 'Cookie': cookie!.header, 'Host': ?hostHeader};
    final uri = webSocketUri(path);
    var abandoned = false;
    try {
      return await WebSocket.connect(uri.toString(), headers: headers, customClient: _http)
          .then((socket) {
            // A timeout does not cancel the upgrade. Own a late socket until it
            // can be handed to the caller; closing HttpClient cannot reclaim it.
            if (abandoned || _closed) {
              unawaited(socket.close().catchError((_) {}));
              throw const DshClosedException('WebSocket connection abandoned');
            }
            return socket;
          })
          .timeout(
            timeout ?? connectTimeout,
            onTimeout: () {
              abandoned = true;
              throw TimeoutException('WebSocket connect timed out');
            },
          );
    } on WebSocketException catch (error) {
      final status = error.httpStatusCode;
      if (status != null) {
        throw DshHttpException(status, 'WebSocket upgrade refused: ${error.message}');
      }
      throw DshTransportException('WebSocket failed: ${error.message}', error);
    } on TimeoutException catch (error) {
      throw DshTransportException('WebSocket connect timed out', error);
    } on SocketException catch (error) {
      throw DshTransportException('WebSocket connect failed: ${error.message}', error);
    } on HttpException catch (error) {
      throw DshTransportException('WebSocket connect failed: ${error.message}', error);
    } on HandshakeException catch (error) {
      throw DshTransportException('TLS handshake failed: ${error.message}', error);
    }
  }

  void close({bool force = false}) {
    _closed = true;
    _backgroundReads?.close();
    if (_ownsClient) _http.close(force: force);
  }

  // ---------------------------------------------------------------------------

  void _trace(String direction, String channel, Object? data) {
    tracer?.call(DshTraceEntry(direction, channel, data));
  }

  Future<DshHttpResponse> _exchange(
    String method,
    Uri uri, {
    List<int>? body,
    String? contentType,
    Map<String, String>? headers,
    bool followRedirects = true,
    int? maxResponseBytes,
    Duration? timeout,
  }) async {
    HttpClientRequest? request;
    StreamIterator<List<int>>? responseBody;
    TimeoutException? expired;
    Future<DshHttpResponse> run() async {
      request = await _http.openUrl(method, uri);
      final req = request!;
      final deadlineError = expired;
      if (deadlineError != null) {
        // openUrl can finish after the exchange deadline (for example, while
        // queued for a connection). Own the aborted request without sending it.
        unawaited(req.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
        req.abort(deadlineError);
        throw deadlineError;
      }
      req.followRedirects = followRedirects;
      _applyHost(req.headers);
      if (cookie != null) req.headers.set(HttpHeaders.cookieHeader, cookie!.header);
      if (contentType != null) req.headers.set(HttpHeaders.contentTypeHeader, contentType);
      headers?.forEach(req.headers.set);
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      final response = await req.close();
      final setCookies = response.headers[HttpHeaders.setCookieHeader] ?? const <String>[];
      final builder = BytesBuilder(copy: false);
      final chunks = responseBody = StreamIterator(response);
      while (await chunks.moveNext()) {
        final chunk = chunks.current;
        if (maxResponseBytes != null && builder.length + chunk.length > maxResponseBytes) {
          request?.abort();
          await chunks.cancel();
          throw DshProtocolException('$method ${uri.path}: response exceeds $maxResponseBytes bytes');
        }
        builder.add(chunk);
      }
      final type = response.headers.contentType;
      return DshHttpResponse(
        response.statusCode,
        type == null ? '' : '${type.primaryType}/${type.subType}'.toLowerCase(),
        builder.takeBytes(),
        setCookies: setCookies,
        contentTypeParameters: type?.parameters ?? const {},
      );
    }

    try {
      return await run().timeout(timeout ?? requestTimeout);
    } on TimeoutException catch (error) {
      expired = error;
      // Once headers arrived, request.abort no longer owns the response body.
      // Start cancellation without extending the caller's total deadline.
      unawaited(responseBody?.cancel().catchError((Object _) {}));
      request?.abort(error);
      throw DshTransportException('$method ${uri.path} timed out', error);
    } on SocketException catch (error) {
      throw DshTransportException('$method ${uri.path} failed: ${error.message}', error);
    } on HttpException catch (error) {
      throw DshTransportException('$method ${uri.path} failed: ${error.message}', error);
    } on HandshakeException catch (error) {
      throw DshTransportException('TLS handshake failed: ${error.message}', error);
    }
  }

  void _applyHost(HttpHeaders headers) {
    final override = hostHeader;
    if (override == null) return;
    final parsed = Uri.tryParse('http://$override');
    if (parsed == null || parsed.host.isEmpty) {
      throw ArgumentError.value(override, 'hostHeader', 'expected host or host:port');
    }
    headers.host = parsed.host;
    headers.port = parsed.hasPort ? parsed.port : 80;
  }

  static Uri _normalizeBase(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError.value(uri, 'baseUri', 'expected an http(s) URL');
    }
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.port, path: path);
  }

  static String _authorityOf(Uri uri) {
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    return uri.port == defaultPort ? host : '$host:${uri.port}';
  }

  static DshCookie? _parseSetCookie(String raw, String authority) {
    final parts = raw.split(';');
    final first = parts.first;
    final eq = first.indexOf('=');
    if (eq <= 0) return null;
    final name = first.substring(0, eq).trim();
    final value = first.substring(eq + 1).trim();
    DateTime? expiresAt;
    for (final attribute in parts.skip(1)) {
      final at = attribute.indexOf('=');
      final key = (at < 0 ? attribute : attribute.substring(0, at)).trim().toLowerCase();
      final attrValue = at < 0 ? '' : attribute.substring(at + 1).trim();
      if (key == 'max-age') {
        final seconds = int.tryParse(attrValue);
        if (seconds != null) {
          expiresAt = DateTime.now().add(Duration(seconds: seconds));
        }
      } else if (key == 'expires' && expiresAt == null) {
        try {
          expiresAt = HttpDate.parse(attrValue);
        } on Object {
          // Keep the cookie without an expiry rather than failing login.
        }
      }
    }
    return DshCookie(name: name, value: value, authority: authority, expiresAt: expiresAt);
  }
}
