// Actual OH DirectDeepSeekSpeech chosen by the real resolver. This explicit
// destination-only client boundary redirects requests to local TCP; the
// request body/headers and real http 1.6 IOClient streaming/close execute.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/host_boundary.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'host-http-tests.dart' show Server;

class EmptyConnection { final Object? value = null; }
class KeySettings { final String apiKey = 'explicit-local-fixture-not-a-credential'; }
class DestinationClient extends http.BaseClient {
  DestinationClient(this.base);
  final Uri base;
  final inner = http.Client();
  int sends = 0, closes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    if (request.url.origin != 'https://api.deepseek.com') throw StateError('unexpected original endpoint');
    final redirected = http.Request(request.method, base.resolve(request.url.path))
      ..headers.addAll(request.headers)
      ..bodyBytes = await request.finalize().toBytes();
    return inner.send(redirected);
  }
  @override
  void close() { closes++; inner.close(); }
}
Future<DeepSeekSpeech> resolve(DestinationClient client) async {
  final ref = Ref({activeConnectionProvider: EmptyConnection(), settingsProvider: KeySettings(),
    deepSeekSpeechHttpProvider: () => client});
  return (await ref.read(deepSeekSpeechProvider)())!;
}

Future<Map<String, Object?>> closeBeforeAndDuringHeaders() async {
  final server = await Server.open();
  final client = DestinationClient(server.base), firstClient = DestinationClient(server.base);
  final first = await resolve(firstClient);
  final speech = await resolve(client);
  try {
    first.close(); final empty = await first.synthesize('closed').toList();
    final reading = speech.synthesize('waiting headers').toList();
    final peer = await server.next(); speech.close();
    final bytes = await reading;
    await peer.closed.future.timeout(const Duration(seconds: 2));
    final again = await speech.synthesize('must not send').toList();
    return {'pass': empty.isEmpty && firstClient.sends == 0 && bytes.isEmpty && again.isEmpty && client.sends == 1 && peer.closed.isCompleted,
      'actualOwnerClass': speech.runtimeType.toString(), 'sendCallsIncludingAfterClose': client.sends,
      'sendCallsAfterAlreadyClosedBeforeStart': firstClient.sends,
      'serverObservedDisconnect': peer.closed.isCompleted, 'closedOwnerBytes': bytes.length + again.length};
  } finally { first.close(); speech.close(); await server.close(); }
}

Future<Map<String, Object?>> errorIdleAndRecovery() async {
  final server = await Server.open();
  final actual = DestinationClient(server.base);
  final owned = await resolve(actual);
  try {
    final timer = Stopwatch()..start();
    final result = owned.synthesize('non-200 stalls').toList().then<Object?>((_) => null, onError: (Object error) => error);
    final peer = await server.next(); await peer.headers(status: 429); await peer.chunk(utf8.encode('{"error":'));
    final error = await result.timeout(const Duration(seconds: 24));
    timer.stop(); await peer.closed.future.timeout(const Duration(seconds: 2));
    final retry = owned.synthesize('retry after failed error body').toList();
    final next = await server.next(); await next.headers(); await next.chunk([1, 2]); await next.end();
    final bytes = (await retry).expand((x) => x).toList();
    return {'pass': error is DeepSeekSpeechError && error.failure == DeepSeekSpeechFailure.busy &&
        peer.closed.isCompleted && jsonEncode(bytes) == '[1,2]' && actual.sends == 2,
      'failure': error.toString(), 'idleDeadlineObservedMs': timer.elapsedMilliseconds,
      'serverObservedDisconnect': peer.closed.isCompleted, 'sameOwnerRetryBytes': bytes,
      'scope': '20s per active diagnostic read, not an absolute total response deadline'};
  } finally { owned.close(); await server.close(); }
}

Future<void> main() async {
  final tests = <String, Future<Map<String, Object?>> Function()>{
    'direct owner cannot send after close and closes pending headers': closeBeforeAndDuringHeaders,
    'short non-200 body has idle timeout and same owner can retry': errorIdleAndRecovery,
  };
  var failed = 0;
  for (final entry in tests.entries) {
    try {
      final result = await entry.value().timeout(const Duration(seconds: 28));
      if (result['pass'] != true) failed++;
      print(jsonEncode({'name': entry.key, ...result}));
    } catch (error, stack) { failed++; print(jsonEncode({'name': entry.key, 'pass': false, 'error': '$error', 'stack': '$stack'})); }
  }
  print(jsonEncode({'scope': 'actual direct OH route, local-only HTTP destination seam', 'tests': tests.length, 'failed': failed}));
  exitCode = failed == 0 ? 0 : 1;
}
