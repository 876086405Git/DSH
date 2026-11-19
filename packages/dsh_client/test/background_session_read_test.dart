import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

Future<HttpServer> host(Future<void> Function(HttpRequest, Map<String, dynamic>) action) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    final text = await utf8.decoder.bind(request).join();
    await action(request, text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>);
  });
  return server;
}

Map<String, Object?> envelope(Map<String, dynamic> request, Object? value) => {
  'type': 'server-response',
  'rpcId': request['rpcId'],
  'result': {'ok': true, 'value': value},
};

Future<void> answer(HttpRequest request, Object? body, {bool compressed = false}) async {
  request.response.headers.contentType = ContentType.json;
  final bytes = utf8.encode(jsonEncode(body));
  if (compressed) request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
  request.response.add(compressed ? gzip.encode(bytes) : bytes);
  await request.response.close();
}

DshClient client(HttpServer server, {bool background = true, DshTracer? tracer, Duration? timeout}) {
  final connection = DshConnection(
    Uri.parse('http://127.0.0.1:${server.port}/mounted'),
    hostHeader: 'localhost:39999',
    cookie: const DshCookie(name: 'dsh-auth-test', value: 'opaque', authority: 'localhost:39999'),
    tracer: tracer,
    requestTimeout: timeout ?? const Duration(seconds: 5),
  );
  final result = DshClient(connection, backgroundSessionLists: background);
  addTearDown(result.close);
  return result;
}

Future<void> eventually(bool Function() condition) async {
  final stop = Stopwatch()..start();
  while (!condition()) {
    if (stop.elapsed > const Duration(seconds: 5)) fail('fixture condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  for (final background in [false, true]) {
    group(background ? 'worker' : 'legacy', () {
      test('preserves request, auth, DTO fields and unknown raw values', () async {
        final fixture = {
          'sessionId': 'child',
          'updatedAt': 12345,
          'running': true,
          'blank': false,
          'agentAvailable': true,
          'cwd': '/with space/中文',
          'parentSessionId': 'parent',
          'origin': 'subagent',
          'projections': {
            'kind': 'cached',
            'asOfSeq': 7,
            'values': {
              'title': '原始标题',
              'future': {'x': 2},
            },
          },
          'futureField': [
            null,
            true,
            42,
            {'nested': 'kept'},
          ],
        };
        final server = await host((request, body) async {
          expect(request.uri.path, '/mounted/api/session/list');
          expect(request.method, 'POST');
          expect(request.headers.value(HttpHeaders.hostHeader), 'localhost:39999');
          expect(request.headers.value(HttpHeaders.cookieHeader), 'dsh-auth-test=opaque');
          expect(body['method'], 'session/list');
          expect(body['payload'], {
            'args': {'_request': {}},
          });
          await answer(
            request,
            envelope(body, {
              'items': [fixture],
            }),
          );
        });
        final row = (await client(server, background: background).listSessions()).single;
        expect(row.raw, fixture);
        expect(row.sessionId, 'child');
        expect(row.updatedAt.millisecondsSinceEpoch, 12345);
        expect(row.isSubagent, isTrue);
        expect(row.parentSessionId, 'parent');
        expect(row.projections.values['future'], {'x': 2});
      });

      test('empty/missing tolerant list shape is unchanged', () async {
        final server = await host((request, body) => answer(request, envelope(body, {'future': 1})));
        expect(await client(server, background: background).listSessions(), isEmpty);
      });

      test('remote invalid-request echo retains typed code and details', () async {
        final server = await host(
          (request, body) => answer(request, {
            'type': 'server-response',
            'rpcId': 'invalid-request',
            'result': {
              'ok': false,
              'error': {
                'code': 'gateway/arguments-invalid',
                'message': 'bad args',
                'details': {'n': 1},
              },
            },
          }),
        );
        await expectLater(
          client(server, background: background).listSessions(),
          throwsA(
            isA<DshRemoteException>().having((e) => e.code, 'code', 'gateway/arguments-invalid').having(
              (e) => e.details,
              'details',
              {'n': 1},
            ),
          ),
        );
      });

      test('success rpcId mismatch is rejected', () async {
        final server = await host((request, body) => answer(request, envelope({'rpcId': 'wrong'}, {'items': []})));
        await expectLater(
          client(server, background: background).listSessions(),
          throwsA(isA<DshProtocolException>().having((e) => e.message, 'message', contains('rpcId mismatch'))),
        );
      });

      test('malformed response keeps protocol error', () async {
        final server = await host((request, body) async {
          request.response.write('{ broken');
          await request.response.close();
        });
        await expectLater(client(server, background: background).listSessions(), throwsA(isA<DshProtocolException>()));
      });

      test('HTTP error retains status and malformed UTF8 replacement', () async {
        final server = await host((request, body) async {
          request.response.statusCode = 403;
          request.response.add([65, 255, 66]);
          await request.response.close();
        });
        await expectLater(
          client(server, background: background).listSessions(),
          throwsA(
            isA<DshHttpException>().having((e) => e.statusCode, 'status', 403).having((e) => e.body, 'body', 'A�B'),
          ),
        );
      });

      test('gzip response uses original tolerant DTO parser', () async {
        final server = await host(
          (request, body) => answer(
            request,
            envelope(body, {
              'items': [
                {'sessionId': 'gzip'},
                null,
              ],
            }),
            compressed: true,
          ),
        );
        final rows = await client(server, background: background).listSessions();
        expect(rows.map((s) => s.sessionId), ['gzip', '']);
      });

      test('multipart raw attachment survives DTO graph transfer', () async {
        final server = await host((request, body) async {
          final data =
              envelope(body, {
                  'items': [
                    {'sessionId': 'binary', 'futureBytes': null},
                  ],
                })
                ..['attachments'] = [
                  {
                    'path': ['items', 0, 'futureBytes'],
                    'codec': 'bytes',
                    'part': 'bytes-0',
                  },
                ];
          const boundary = 'wave7-boundary';
          request.response.headers.set('content-type', 'multipart/form-data; boundary=$boundary');
          request.response.add([
            ...utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="metadata"\r\n\r\n'),
            ...utf8.encode(jsonEncode(data)),
            ...utf8.encode('\r\n--$boundary\r\nContent-Disposition: form-data; name="bytes-0"\r\n\r\n'),
            0,
            255,
            10,
            42,
            ...utf8.encode('\r\n--$boundary--\r\n'),
          ]);
          await request.response.close();
        });
        final row = (await client(server, background: background).listSessions()).single;
        expect(row.raw['futureBytes'], isA<Uint8List>());
        expect(row.raw['futureBytes'], [0, 255, 10, 42]);
      });
    });
  }

  test('opt-in keeps custom postJson override and incoming tracer mutation', () async {
    final connection = _CustomConnection();
    connection.tracer = (entry) {
      if (entry.direction == 'in' && entry.channel == 'rpc') {
        final root = entry.data as Map;
        final body = root['body'] as Map;
        (body['result'] as Map)['value'] = {
          'items': [
            {'sessionId': 'mutated'},
          ],
        };
      }
    };
    final c = DshClient(connection, backgroundSessionLists: true);
    addTearDown(c.close);
    expect((await c.listSessions()).single.sessionId, 'mutated');
    expect(connection.calls, 1);
  });

  test('a connection created under HttpOverrides retains that transport outside its zone', () async {
    final server = await host((request, body) async {
      expect(request.headers.value(HttpHeaders.userAgentHeader), 'override-agent');
      await answer(
        request,
        envelope(body, {
          'items': [
            {'sessionId': 'override'},
          ],
        }),
      );
    });
    final http = HttpClient()..userAgent = 'override-agent';
    late DshConnection connection;
    HttpOverrides.runZoned(() {
      connection = DshConnection(Uri.parse('http://127.0.0.1:${server.port}'));
    }, createHttpClient: (context) => http);
    expect(connection.canReadSessionsInBackground, isFalse);
    final c = DshClient(connection, backgroundSessionLists: true);
    addTearDown(c.close);
    expect((await c.listSessions()).single.sessionId, 'override');
  });

  test('an injected HttpClient stays on its original path', () async {
    final server = await host((request, body) async {
      expect(request.headers.value(HttpHeaders.userAgentHeader), 'injected-agent');
      await answer(
        request,
        envelope(body, {
          'items': [
            {'sessionId': 'injected'},
          ],
        }),
      );
    });
    final http = HttpClient()..userAgent = 'injected-agent';
    addTearDown(() => http.close(force: true));
    final connection = DshConnection(Uri.parse('http://127.0.0.1:${server.port}'), httpClient: http);
    expect(connection.canReadSessionsInBackground, isFalse);
    final c = DshClient(connection, backgroundSessionLists: true);
    addTearDown(c.close);
    expect((await c.listSessions()).single.sessionId, 'injected');
  });

  test('record tracer exceptions keep their original failure', () async {
    final connection = _CustomConnection();
    connection.tracer = (entry) {
      if (entry.direction == 'in') throw StateError('trace failure');
    };
    final c = DshClient(connection, backgroundSessionLists: true);
    addTearDown(c.close);
    await expectLater(
      c.listSessions(),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'trace failure')),
    );
  });

  test('two active reads and eight queued; saturation fails without truncation', () async {
    final accepted = <HttpRequest>[];
    final server = await host((request, body) async {
      accepted.add(request);
    });
    final c = client(server);
    final reads = List.generate(10, (_) => c.listSessions());
    final rejected = expectLater(c.listSessions(), throwsA(isA<DshTransportException>()));
    // Observe logical outcomes immediately to avoid unhandled cancellation.
    final closed = reads.map((read) => expectLater(read, throwsA(isA<DshClosedException>()))).toList();
    await rejected;
    await eventually(() => accepted.length == 2);
    c.connection.close();
    await Future.wait(closed);
    final nextServer = await host(
      (request, body) => answer(
        request,
        envelope(body, {
          'items': [
            {'sessionId': 'next'},
          ],
        }),
      ),
    );
    expect((await client(nextServer).listSessions()).single.sessionId, 'next');
    expect(accepted.length, 2);
  });

  test('timeout during body retires owned read, another RPC still completes', () async {
    final bodyStarted = Completer<void>();
    final server = await host((request, body) async {
      if (body['method'] == 'session/list') {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"partial":');
        await request.response.flush();
        bodyStarted.complete();
      } else {
        await answer(request, envelope(body, {'alive': true}));
      }
    });
    final c = client(server, timeout: const Duration(seconds: 2));
    final pending = c.listSessions();
    final failed = expectLater(pending, throwsA(isA<DshTransportException>()));
    await bodyStarted.future;
    expect(await c.rpc.call('test/independent'), {'alive': true});
    await failed;
    expect(await c.rpc.call('test/independent'), {'alive': true});
  });

  test('POST 303 hidden GET is owned by worker and cancellation is isolated', () async {
    Map<String, dynamic>? original;
    final redirected = Completer<void>();
    final server = await host((request, body) async {
      if (request.method == 'GET') {
        request.response.write('{"partial":');
        await request.response.flush();
        redirected.complete();
      } else if (body['method'] == 'session/list') {
        original = body;
        request.response.statusCode = 303;
        request.response.headers.set('location', '/redirect-target');
        await request.response.close();
      } else {
        await answer(request, envelope(body, {'alive': true}));
      }
    });
    final c = client(server, timeout: const Duration(seconds: 2));
    final failed = expectLater(c.listSessions(), throwsA(isA<DshTransportException>()));
    await redirected.future;
    expect(original?['method'], 'session/list');
    expect(await c.rpc.call('test/independent'), {'alive': true});
    await failed;
    expect(await c.rpc.call('test/independent'), {'alive': true});
  });

  test('decompressed body over budget fails and a later read recovers', () async {
    var calls = 0;
    final server = await host((request, body) async {
      if (calls++ == 0) {
        await answer(
          request,
          envelope(body, {
            'items': [
              {'sessionId': 'x', 'large': 'x' * (64 * 1024 * 1024)},
            ],
          }),
          compressed: true,
        );
      } else {
        await answer(
          request,
          envelope(body, {
            'items': [
              {'sessionId': 'recovered'},
            ],
          }),
        );
      }
    });
    final c = client(server);
    await expectLater(
      c.listSessions(),
      throwsA(isA<DshProtocolException>().having((e) => e.message, 'message', contains('67108864'))),
    );
    expect((await c.listSessions()).single.sessionId, 'recovered');
  });

  test('changing tracer retires in-flight worker before record fallback', () async {
    final waiting = Completer<void>();
    final server = await host((request, body) async {
      if (!waiting.isCompleted) {
        waiting.complete();
      } else {
        await answer(
          request,
          envelope(body, {
            'items': [
              {'sessionId': 'recorded'},
            ],
          }),
        );
      }
    });
    final c = client(server);
    final failure = expectLater(c.listSessions(), throwsA(isA<DshClosedException>()));
    await waiting.future;
    final trace = <DshTraceEntry>[];
    c.connection.tracer = trace.add;
    await failure;
    expect((await c.listSessions()).single.sessionId, 'recorded');
    expect(trace.where((e) => e.channel == 'rpc' && e.direction == 'in'), hasLength(1));
  });

  test('three-second slow engine leaves calling-isolate timers responsive', () async {
    final arrived = Completer<void>();
    final release = Completer<void>();
    final server = await host((request, body) async {
      arrived.complete();
      await release.future;
      await answer(
        request,
        envelope(body, {
          'items': [
            {'sessionId': 'slow'},
          ],
        }),
      );
    });
    final c = client(server);
    final pending = c.listSessions();
    await arrived.future;
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 50), (_) => ticks++);
    await Future<void>.delayed(const Duration(seconds: 3));
    timer.cancel();
    expect(ticks, greaterThan(10));
    release.complete();
    expect((await pending).single.sessionId, 'slow');
  });
}

class _CustomConnection extends DshConnection {
  _CustomConnection() : super(Uri.parse('http://unused.invalid'));
  int calls = 0;
  @override
  Future<DshHttpResponse> postJson(String path, Object? body, {Duration? timeout}) async {
    calls++;
    return DshHttpResponse(
      200,
      'application/json',
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(
            envelope((body as Map).cast<String, dynamic>(), {
              'items': [
                {'sessionId': 'original'},
              ],
            }),
          ),
        ),
      ),
    );
  }
}
