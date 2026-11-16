// No paid API. Real Dart HttpClient -> local TCP, with explicit raw HTTP
// framing so response EOF and peer disconnection are independently observed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dsh_client/dsh_client.dart';

class Peer {
  Peer(this.socket) {
    socket.listen((_) {}, onError: (Object _) { if (!closed.isCompleted) closed.complete(); },
      onDone: () { if (!closed.isCompleted) closed.complete(); });
  }
  final Socket socket;
  final closed = Completer<void>();
  Future<void> headers({int status = 200}) async {
    socket.write('HTTP/1.1 $status fixture\r\nContent-Type: audio/pcm\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n');
    await socket.flush();
  }
  Future<void> chunk(List<int> bytes) async {
    socket.write('${bytes.length.toRadixString(16)}\r\n'); socket.add(bytes); socket.write('\r\n'); await socket.flush();
  }
  Future<void> end() async { socket.write('0\r\n\r\n'); await socket.flush(); }
  void destroy() => socket.destroy();
}

class Server {
  Server._(this.server) {
    subscription = server.listen((req) async {
      paths.add(req.uri.path);
      if (req.uri.path == '/health') {
        req.response.write('ok'); await req.response.close(); return;
      }
      bodies.add(await utf8.decoder.bind(req).join());
      hosts.add(req.headers.value(HttpHeaders.hostHeader));
      cookies.add(req.headers.value(HttpHeaders.cookieHeader));
      final peer = Peer(await req.response.detachSocket(writeHeaders: false));
      peers.add(peer); pending.add(peer);
    });
  }
  static Future<Server> open() async => Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  final HttpServer server;
  late final StreamSubscription<HttpRequest> subscription;
  final pending = StreamController<Peer>();
  late final iterator = StreamIterator<Peer>(pending.stream);
  final peers = <Peer>[];
  final paths = <String>[], bodies = <String>[];
  final hosts = <String?>[], cookies = <String?>[];
  Uri get base => Uri.parse('http://127.0.0.1:${server.port}');
  Future<Peer> next() async {
    if (!await iterator.moveNext().timeout(const Duration(seconds: 2))) throw StateError('no peer');
    return iterator.current;
  }
  Future<void> close() async {
    for (final peer in peers) { peer.destroy(); }
    await iterator.cancel(); await pending.close(); await subscription.cancel(); await server.close(force: true);
  }
}

Future<Map<String, Object?>> cancelUnconsumed() async {
  final server = await Server.open();
  final connection = DshConnection(server.base), abort = DshHttpAbort();
  try {
    final pending = connection.postJsonStream('/stream', {'fixture': 1}, abort: abort);
    final peer = await server.next(); await peer.headers();
    final response = await pending;
    abort.abort();
    await peer.closed.future.timeout(const Duration(seconds: 2));
    final bytes = await response.body.expand((x) => x).toList();
    final health = await connection.get('/health');
    return {'pass': bytes.isEmpty && health.statusCode == 200 && peer.closed.isCompleted,
      'bodyListenedOnlyAfterAbort': true, 'responseBytesAfterAbort': bytes.length,
      'serverObservedDisconnect': peer.closed.isCompleted, 'sameConnectionHealth': health.statusCode};
  } finally { connection.close(force: true); await server.close(); }
}

Future<Map<String, Object?>> cancelHeaders() async {
  final server = await Server.open();
  final connection = DshConnection(server.base), abort = DshHttpAbort();
  try {
    final pending = connection.postJsonStream('/stream', {'fixture': 2}, abort: abort);
    // Install an error observer before cancelling, independently of socket EOF.
    final observed = pending.then<Object?>((_) => null, onError: (Object error) => error);
    final peer = await server.next();
    abort.abort();
    final error = await observed.timeout(const Duration(seconds: 2));
    await peer.closed.future.timeout(const Duration(seconds: 2));
    return {'pass': error is DshClosedException && peer.closed.isCompleted,
      'serverSentResponseHeaders': false, 'resultType': error.runtimeType.toString(),
      'serverObservedDisconnect': peer.closed.isCompleted};
  } finally { connection.close(force: true); await server.close(); }
}

Future<Map<String, Object?>> pausedBody() async {
  final server = await Server.open();
  final connection = DshConnection(server.base), abort = DshHttpAbort();
  StreamIterator<Uint8List>? reader;
  try {
    final pending = connection.postJsonStream('/stream', {}, abort: abort, idleTimeout: const Duration(milliseconds: 80));
    final peer = await server.next(); await peer.headers(); await peer.chunk([1, 2, 3]);
    final response = await pending;
    reader = StreamIterator(response.body);
    final first = await reader.moveNext();
    final bytes = <int>[...reader.current];
    await Future<void>.delayed(const Duration(milliseconds: 240));
    final stillOpen = !peer.closed.isCompleted;
    await peer.chunk([4, 5, 6]);
    final second = await reader.moveNext(); bytes.addAll(reader.current);
    await peer.end(); final finished = !await reader.moveNext();
    return {'pass': first && second && finished && stillOpen && jsonEncode(bytes) == '[1,2,3,4,5,6]',
      'idleTimeoutMs': 80, 'consumerPausedMs': 240, 'connectionOpenDuringPause': stillOpen,
      'bytes': bytes, 'eof': finished};
  } finally { await reader?.cancel(); connection.close(force: true); await server.close(); }
}

Future<Map<String, Object?>> bodyStall() async {
  final server = await Server.open();
  final connection = DshConnection(server.base), abort = DshHttpAbort();
  StreamIterator<Uint8List>? reader;
  try {
    final pending = connection.postJsonStream('/stream', {}, abort: abort, idleTimeout: const Duration(milliseconds: 60));
    final peer = await server.next(); await peer.headers(); await peer.chunk([1, 2]);
    final response = await pending;
    reader = StreamIterator(response.body); await reader.moveNext();
    Object? failure;
    try { await reader.moveNext(); } catch (error) { failure = error; }
    await peer.closed.future.timeout(const Duration(seconds: 2));
    return {'pass': failure is DshTransportException && peer.closed.isCompleted,
      'errorType': failure.runtimeType.toString(), 'serverObservedDisconnect': peer.closed.isCompleted};
  } finally { await reader?.cancel(); connection.close(force: true); await server.close(); }
}

Future<Map<String, Object?>> finiteLarge() async {
  final server = await Server.open();
  final connection = DshConnection(server.base), abort = DshHttpAbort();
  try {
    final pending = connection.postJsonStream('/stream', {}, abort: abort);
    final peer = await server.next(); await peer.headers();
    const count = 4 * 1024 * 1024 + 6;
    final response = await pending;
    var consumed = 0, largest = 0, chunks = 0, correct = true;
    final reading = () async {
      await for (final chunk in response.body) {
        chunks++; if (chunk.length > largest) largest = chunk.length;
        for (final byte in chunk) { if (byte != (consumed++ % 251)) correct = false; }
      }
    }();
    var produced = 0;
    while (produced < count) {
      final size = count - produced < 65537 ? count - produced : 65537;
      final chunk = Uint8List.fromList(List<int>.generate(size, (i) => (produced + i) % 251));
      await peer.chunk(chunk); produced += size;
    }
    await peer.end(); await reading;
    return {'pass': correct && consumed == count,
      'httpBytes': produced, 'bodyBytes': consumed, 'actualHttpClientChunks': chunks,
      'largestObservedHttpClientChunk': largest, 'orderedBytesMatch': correct,
      'scope': 'observed socket chunk sizes; not a universal memory cap'};
  } finally { connection.close(force: true); await server.close(); }
}

Future<Map<String, Object?>> lateOpen({required bool timeout}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final entered = Completer<void>(), release = Completer<void>();
  final paths = <String>[];
  server.listen((req) async {
    paths.add(req.uri.path);
    if (req.uri.path == '/occupied') { entered.complete(); await release.future; }
    await req.drain<void>(); req.response.write('ok'); await req.response.close();
  });
  final http = HttpClient()..maxConnectionsPerHost = 1;
  final base = Uri.parse('http://127.0.0.1:${server.port}');
  final connection = DshConnection(base, httpClient: http), abort = DshHttpAbort();
  try {
    final occupied = await http.getUrl(base.resolve('/occupied'));
    final draining = occupied.close().then((response) => response.drain<void>());
    await entered.future;
    final pending = connection.postJsonStream('/must-not-be-sent', {'fixture': true}, abort: abort,
      headerTimeout: Duration(milliseconds: timeout ? 30 : 2000));
    final observed = pending.then<Object?>((_) => null, onError: (Object error) => error);
    if (!timeout) abort.abort();
    final error = await observed.timeout(const Duration(seconds: 2));
    release.complete(); await draining;
    final barrier = await http.getUrl(base.resolve('/barrier'));
    await (await barrier.close()).drain<void>();
    return {'pass': (timeout ? error is DshTransportException : error is DshClosedException) &&
        jsonEncode(paths) == '["/occupied","/barrier"]',
      'errorType': error.runtimeType.toString(), 'serverPathsAfterRealQueueBarrier': paths};
  } finally {
    if (!release.isCompleted) release.complete(); connection.close(); http.close(force: true); await server.close(force: true);
  }
}

Future<void> main() async {
  final tests = <String, Future<Map<String, Object?>> Function()>{
    'abort headers-owned body before caller listens': cancelUnconsumed,
    'abort before response headers': cancelHeaders,
    'consumer pause is not network-idle timeout': pausedBody,
    'body idle timeout retires socket': bodyStall,
    'real HTTP over four MiB preserves full PCM': finiteLarge,
    'queued late open after abort sends no POST': () => lateOpen(timeout: false),
    'queued late open after header deadline sends no POST': () => lateOpen(timeout: true),
    'completed stream exchanges retain HTTP connection reuse': healthyReuse,
  };
  var failed = 0;
  for (final entry in tests.entries) {
    try {
      final result = await entry.value().timeout(const Duration(seconds: 6));
      if (result['pass'] != true) failed++;
      print(jsonEncode({'name': entry.key, ...result}));
    } catch (error, stack) { failed++; print(jsonEncode({'name': entry.key, 'pass': false, 'error': '$error', 'stack': '$stack'})); }
  }
  print(jsonEncode({'scope': 'real Dart HttpClient and local TCP; no provider/API requests', 'tests': tests.length, 'failed': failed}));
  exitCode = failed == 0 ? 0 : 1;
}

Future<Map<String, Object?>> healthyReuse() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final peerPorts = <int>[], requestClose = <bool>[];
  server.listen((req) async {
    peerPorts.add(req.connectionInfo!.remotePort);
    requestClose.add(req.headers.value(HttpHeaders.connectionHeader)?.toLowerCase() == 'close');
    await req.drain<void>();
    req.response.headers.contentType = ContentType.binary;
    req.response.contentLength = 2; req.response.add([1, 2]); await req.response.close();
  });
  final http = HttpClient()..maxConnectionsPerHost = 1;
  final connection = DshConnection(Uri.parse('http://127.0.0.1:${server.port}'), httpClient: http);
  try {
    var bytes = 0;
    for (var i = 0; i < 3; i++) {
      final response = await connection.postJsonStream('/stream', {}, abort: DshHttpAbort());
      await for (final chunk in response.body) { bytes += chunk.length; }
    }
    return {'pass': bytes == 6 && peerPorts.toSet().length == 1 && requestClose.every((x) => !x),
      'requests': peerPorts.length, 'distinctServerObservedPeerPorts': peerPorts.toSet().length,
      'connectionCloseRequested': requestClose, 'receivedBytes': bytes};
  } finally { connection.close(); http.close(force: true); await server.close(force: true); }
}
