import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

class _Headers implements HttpHeaders {
  final values = <String, Object>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  @override
  final _Headers headers = _Headers();
  bool aborted = false;
  int added = 0, closed = 0;
  @override
  bool followRedirects = true;
  @override
  int contentLength = 0;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
  }

  @override
  void add(List<int> data) {
    added += data.length;
  }

  @override
  Future<HttpClientResponse> get done => Future.error(const HttpException('test request has no server'));

  @override
  Future<HttpClientResponse> close() {
    closed++;
    return Future.error(const HttpException('test request has no server'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedClient implements HttpClient {
  final opened = Completer<void>();
  final gate = Completer<HttpClientRequest>();
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    opened.complete();
    return gate.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final timeout in [false, true]) {
    test('${timeout ? 'timeout' : 'explicit abort'} before openUrl returns cannot send late headers or body', () async {
      final transport = _DelayedClient();
      final connection = DshConnection(
        Uri.parse('http://127.0.0.1:3080'),
        httpClient: transport,
        cookie: const DshCookie(name: 'dsh-auth-test', value: 'test-cookie', authority: '127.0.0.1:3080'),
      );
      final abort = DshHttpAbort();
      final pending = connection.postBytes(
        '/dsh-go/v1/phone/claim',
        [1, 2, 3],
        abort: abort,
        timeout: Duration(milliseconds: timeout ? 25 : 1000),
      );
      final expected = expectLater(
        pending,
        throwsA(timeout ? isA<DshTransportException>() : isA<DshClosedException>()),
      );
      await transport.opened.future;
      if (!timeout) abort.abort();
      await expected.timeout(const Duration(seconds: 2));
      final request = _Request();
      transport.gate.complete(request);
      await Future<void>.delayed(Duration.zero);
      print({
        'lateRequestAborted': request.aborted,
        'headerCount': request.headers.values.length,
        'bodyBytes': request.added,
        'closeCalls': request.closed,
      });
      expect(request.aborted, isTrue);
      expect(request.headers.values, isEmpty);
      expect(request.added, 0);
      expect(request.closed, 0);
      abort.abort();
      connection.close();
    });
  }
}
