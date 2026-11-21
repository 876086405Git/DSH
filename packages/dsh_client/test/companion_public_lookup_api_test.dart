import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const _path = '/dsh-go/v1/companion/lookup';
const _task = <String, Object?>{
  'placeName': '青桥美术馆',
  'city': null,
  'localDate': '2026-11-21',
  'zoneId': 'Asia/Shanghai',
  'question': '今天开不开，给我馆方公告',
};
const _identity = {'requestId': 'request-1', 'taskId': 'task-1', 'taskRev': 1};
const _capability = <String, Object?>{
  'v': 1,
  'instanceId': 'instance-1',
  'provider': 'deepseek',
  'model': 'deepseek-flash',
  'direct': {'search': true, 'fetch': true, 'physicalDispatch': 'fetch-invoked', 'maxPhysicalRequests': 1},
  'answer': {
    'noTools': true,
    'physicalDispatch': 'fetch-invoked',
    'rawUsage': 'deepseek-messages-cumulative',
    'maxPhysicalRequests': 1,
  },
};

Map<String, Object?> _accepted() => {
  ..._identity,
  'type': 'accepted',
  'instanceId': 'instance-1',
  'provider': 'deepseek',
  'model': 'deepseek-flash',
};
Map<String, Object?> _dispatch() => {..._identity, 'type': 'dispatch', 'boundary': 'fetch-invoked', 'atMs': 1000};
Map<String, Object?> _http() => {..._identity, 'type': 'http', 'status': 200, 'atMs': 1001};
Map<String, Object?> _finish({bool? dispatched = true, Object? result, Map<String, Object?>? usage}) => {
  ..._identity,
  'type': 'finish',
  'dispatched': dispatched,
  'dispatchAtMs': dispatched == true ? 1000 : null,
  'httpStatus': dispatched == true ? 200 : null,
  'terminal': 'complete',
  'complete': true,
  'result': result,
  'bodyRetained': false,
  'usage': usage,
};

Future<void> _json(HttpRequest request, Object? value, {int status = 200}) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(value));
  await request.response.close();
}

Future<void> _frames(HttpRequest request, List<Map<String, Object?>> frames) async {
  request.response.headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
  for (final frame in frames) {
    request.response.write('${jsonEncode(frame)}\n');
  }
  await request.response.close();
}

class _Host {
  _Host(this.server) {
    server.listen((request) async {
      requests.add(request);
      final body = await utf8.decoder.bind(request).join();
      bodies.add(body.isEmpty ? null : jsonDecode(body));
      await answer(request);
    });
  }
  final HttpServer server;
  final requests = <HttpRequest>[];
  final bodies = <Object?>[];
  late Future<void> Function(HttpRequest) answer = (request) => _json(request, _capability);
  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}');
}

// These fixed peers match the frozen E02 handler's wire contract. They test
// the real Dart connection and decoder, not a live engine or paid provider.
void main() {
  late _Host host;
  late DshClient client;
  late List<Map<String, Object?>> events;
  setUp(() async {
    host = _Host(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    client = DshClient(
      DshConnection(
        host.uri,
        hostHeader: host.uri.authority,
        cookie: DshCookie(name: 'dsh-auth-test', value: 'fixture-cookie', authority: host.uri.authority),
      ),
    );
    events = [];
  });
  tearDown(() async {
    await client.close();
    await host.server.close(force: true);
  });

  Future<Map<String, Object?>> call(
    CompanionLookupCapability capability, {
    String kind = 'search',
    Map<String, Object?> payload = const {'query': '青桥美术馆 2026-11-21 开放 公告'},
    DshHttpAbort? abort,
    void Function()? handoff,
  }) => client.callCompanionLookup(
    capability,
    requestId: 'request-1',
    taskId: 'task-1',
    taskRev: 1,
    deadlineAtMs: 121000,
    kind: kind,
    task: _task,
    payload: payload,
    abort: abort ?? DshHttpAbort(),
    onHandoff: handoff ?? () => events.add({'type': 'handoff'}),
    onEvent: events.add,
  );

  test('E SDK actual HTTP preserves original task selection authentication and raw tool observations', () async {
    final capability = (await client.readCompanionLookupCapability('original-session'))!;
    expect(capability.search, isTrue);
    expect(capability.fetch, isTrue);
    expect(capability.answer, isTrue);
    final raw = {
      'results': [
        {
          'url': 'https://museum.example/notice',
          'title': '馆方公告🙂',
          'snippet': '摘要',
          'summary': '长摘要',
          'content': '',
          'authority': 4,
          'rerank_score': 2.8,
          'date': null,
        },
      ],
    };
    host.answer = (request) {
      expect(events.single['type'], 'handoff');
      expect(request.headers.value(HttpHeaders.cookieHeader), 'dsh-auth-test=fixture-cookie');
      expect(request.headers.value(HttpHeaders.hostHeader), host.uri.authority);
      expect(host.bodies.last, {
        'v': 1,
        'instanceId': 'instance-1',
        'requestId': 'request-1',
        'sessionId': 'original-session',
        'taskId': 'task-1',
        'taskRev': 1,
        'deadlineAtMs': 121000,
        'provider': 'deepseek',
        'model': 'deepseek-flash',
        'kind': 'search',
        'task': _task,
        'payload': {'query': '青桥美术馆 2026-11-21 开放 公告'},
      });
      return _frames(request, [
        _accepted(),
        _dispatch(),
        _http(),
        {..._identity, 'type': 'provider-result', 'raw': raw},
        _finish(
          result: {
            'sources': [
              {'url': 'https://museum.example/notice'},
            ],
            'metadataOnly': true,
          },
        ),
      ]);
    };
    final result = await call(capability);
    expect(result['dispatched'], isTrue);
    expect(events.singleWhere((event) => event['type'] == 'provider-result')['raw'], raw);
    expect(events.map((event) => event['type']), [
      'handoff',
      'accepted',
      'dispatch',
      'http',
      'provider-result',
      'finish',
    ]);
    expect(host.requests.map((request) => request.uri.path), [_path, _path]);
    expect(host.requests.first.uri.queryParameters, {'sessionId': 'original-session'});
  });

  test('E SDK Fetch body is delivered once while recovery explicitly contains no retained page', () async {
    final capability = (await client.readCompanionLookupCapability('original-session'))!;
    final finished = _finish(result: {'url': 'https://museum.example/notice'});
    host.answer = (request) => _frames(request, [
      _accepted(),
      _dispatch(),
      _http(),
      {
        ..._identity,
        'type': 'provider-result',
        'raw': {'title': '馆方', 'content': '实际完整正文'},
      },
      finished,
    ]);
    await call(capability, kind: 'fetch', payload: {'url': 'https://museum.example/notice'});
    expect(events.singleWhere((event) => event['type'] == 'provider-result')['raw'], {
      'title': '馆方',
      'content': '实际完整正文',
    });
    host.answer = (request) => _json(request, {
      'v': 1,
      'instanceId': 'instance-1',
      ..._identity,
      'phase': 'finished',
      'bodyRetained': false,
      'dispatched': true,
      'dispatchAtMs': 1000,
      'finish': finished,
    });
    final receipt = await client.readCompanionLookupRequest(
      instanceId: 'instance-1',
      requestId: 'request-1',
      taskId: 'task-1',
      taskRev: 1,
    );
    expect(receipt!['bodyRetained'], isFalse);
    expect(jsonEncode(receipt), isNot(contains('实际完整正文')));
    expect(host.requests.where((request) => request.method == 'POST'), hasLength(1));
    expect(host.requests.last.uri.path, '$_path/requests/request-1');
  });

  for (final code in ['request-used', 'request-conflict', 'instance-changed', 'request-unknown']) {
    test('E SDK $code cannot release or automatically repeat a prior request', () async {
      final capability = (await client.readCompanionLookupCapability('original-session'))!;
      host.answer = (request) => _json(request, {
        'error': {'code': 'companion/lookup-$code'},
        'dispatched': false,
      }, status: 409);
      await expectLater(
        call(capability),
        throwsA(isA<CompanionLookupFailure>().having((e) => e.notSent, 'notSent', false)),
      );
      expect(host.requests.where((request) => request.method == 'POST'), hasLength(1));
      expect(events.map((event) => event['type']), ['handoff']);
    });
  }

  test('E SDK explicit preflight refusal and old-route discovery are distinguished', () async {
    final capability = (await client.readCompanionLookupCapability('original-session'))!;
    host.answer = (request) => _json(request, {
      'error': {'code': 'companion/lookup-forbidden'},
      'dispatched': false,
    }, status: 403);
    await expectLater(
      call(capability),
      throwsA(isA<CompanionLookupFailure>().having((e) => e.notSent, 'notSent', true)),
    );
    host.answer = (request) => _json(request, {
      'error': {'code': 'companion/not-found'},
    }, status: 404);
    expect(await client.readCompanionLookupCapability('original-session'), isNull);
    expect(host.requests.where((request) => request.method == 'POST'), hasLength(1));
  });

  test('E SDK failed durable handoff or pre-abort prevents the actual POST', () async {
    final capability = (await client.readCompanionLookupCapability('original-session'))!;
    await expectLater(call(capability, handoff: () => throw StateError('storage failure')), throwsStateError);
    final abort = DshHttpAbort()..abort();
    await expectLater(
      call(capability, abort: abort),
      throwsA(isA<CompanionLookupFailure>().having((e) => e.notSent, 'notSent', true)),
    );
    expect(host.requests, hasLength(1));
    expect(events, isEmpty);
  });

  for (final fault in ['wrong-revision', 'false-after-dispatch', 'missing-newline']) {
    test('E SDK $fault keeps the stream uncertain after actual handoff', () async {
      final capability = (await client.readCompanionLookupCapability('original-session'))!;
      host.answer = (request) async {
        request.response.headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
        for (final frame in [_accepted(), _dispatch()]) {
          request.response.write('${jsonEncode(frame)}\n');
        }
        final finish = _finish();
        if (fault == 'wrong-revision') {
          finish['taskRev'] = 2;
        } else if (fault == 'false-after-dispatch') {
          finish['dispatched'] = false;
          finish['dispatchAtMs'] = null;
        }
        request.response.write('${jsonEncode(finish)}${fault == 'missing-newline' ? '' : '\n'}');
        await request.response.close();
      };
      await expectLater(
        call(capability),
        throwsA(isA<CompanionLookupFailure>().having((e) => e.notSent, 'notSent', false)),
      );
      expect(events.where((event) => event['type'] == 'dispatch'), hasLength(1));
      expect(events.where((event) => event['type'] == 'finish'), isEmpty);
    });
  }

  test('E SDK original-instance fence sends only the exact new cancellation revision', () async {
    host.answer = (request) {
      expect(request.headers.contentType?.mimeType, 'application/json');
      expect(host.bodies.single, {
        'v': 1,
        'instanceId': 'old-instance',
        'sessionId': 'original-session',
        'taskId': 'task-1',
        'taskRev': 2,
        'cancelled': true,
        'deadlineAtMs': 121000,
      });
      return _json(request, {
        'v': 1,
        'instanceId': 'old-instance',
        'taskId': 'task-1',
        'taskRev': 2,
        'cancelled': true,
        'received': true,
      });
    };
    await client.fenceCompanionLookup(
      instanceId: 'old-instance',
      sessionId: 'original-session',
      taskId: 'task-1',
      taskRev: 2,
      cancelled: true,
      deadlineAtMs: 121000,
    );
    expect(host.requests.single.uri.path, '$_path/fence');
  });

  test('E SDK prepared input-limit receipt keeps its budget separate from real usage', () async {
    final capability = (await client.readCompanionLookupCapability('original-session'))!;
    const budget = {
      'estimatedTokens': 12001,
      'outputReserve': 800,
      'contextWindow': 32768,
      'scope': 'provider-request',
      'estimator': 'companion-heuristic-v1',
    };
    const usage = {
      'provider': 'deepseek',
      'model': 'deepseek-flash',
      'start_usage': null,
      'final_usage': null,
      'input_uncached': null,
      'input_cache_read': null,
      'input_cache_write': null,
      'output_tokens': null,
    };
    host.answer = (request) => _frames(request, [
      _accepted(),
      {
        ..._finish(dispatched: false, usage: usage),
        'terminal': 'preflight_error',
        'complete': false,
        'error': {'code': 'companion/lookup-input-limit'},
        'inputBudget': budget,
      },
    ]);
    final result = await call(
      capability,
      kind: 'answer',
      payload: {
        'sources': [
          {
            'fetchRequestId': 'fetch-1',
            'url': 'https://museum.example/notice',
            'title': '',
            'content': '实际完整正文',
            'fetchedAtMs': 1000,
          },
        ],
      },
    );
    expect(result['dispatched'], isFalse);
    expect(result['complete'], isFalse);
    expect(result['inputBudget'], budget);
    expect(result['usage'], usage);
    expect(events.where((event) => event['type'] == 'dispatch'), isEmpty);
    expect(host.requests.where((request) => request.method == 'POST'), hasLength(1));
  });

  test('E SDK answer retains physical unknown and normalized usage under their original names', () async {
    host.answer = (request) => _json(request, {
      ..._capability,
      'provider': 'generic',
      'model': 'selected-model',
      'answer': {
        'noTools': true,
        'physicalDispatch': 'unknown',
        'rawUsage': 'unavailable',
        'maxPhysicalRequests': null,
      },
    });
    final capability = (await client.readCompanionLookupCapability('original-session'))!;
    const usage = {
      'provider': 'generic',
      'model': 'selected-model',
      'start_usage': null,
      'final_usage': null,
      'input_uncached': null,
      'output_tokens': null,
      'runtime_normalized_usage': [
        {'inputTokens': 4, 'outputTokens': 2},
      ],
    };
    host.answer = (request) => _frames(request, [
      {..._accepted(), 'provider': 'generic', 'model': 'selected-model'},
      {
        ..._identity,
        'type': 'runtime-usage',
        'semantics': 'runtime-normalized',
        'usage': {'inputTokens': 4, 'outputTokens': 2},
      },
      {..._identity, 'type': 'text', 'text': '{"status":"partial"}'},
      _finish(dispatched: null, result: {'text': '{"status":"partial"}'}, usage: usage),
    ]);
    final result = await call(
      capability,
      kind: 'answer',
      payload: {
        'sources': [
          {
            'fetchRequestId': 'fetch-1',
            'url': 'https://museum.example/notice',
            'title': '',
            'content': '材料',
            'fetchedAtMs': 1000,
          },
        ],
      },
    );
    expect(result['dispatched'], isNull);
    expect(result['dispatchAtMs'], isNull);
    expect(result['usage'], usage);
    expect(events.where((event) => event['type'] == 'dispatch'), isEmpty);
  });
}
