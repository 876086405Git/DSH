import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

// Literal outputs of production routes plus locked LlmRuntime/adapter source.
// Captured by checks/A05-usage-wire-fixtures.mjs, without real model network.
// The oldRoute case is the actual original da7980270 companion route.
const _hostWireJson = r'''
{
  "pending": {
    "status": 200,
    "body": {
      "v": 1,
      "instanceId": "chat-instance",
      "sessionId": "chat-session",
      "requestId": "phone-request",
      "binding": {
        "archiveId": "phone-archive",
        "controlRevision": 0,
        "historyAfterSeq": 0
      },
      "state": "pending",
      "complete": false,
      "revision": 1,
      "gaps": [],
      "observedAdapterCalls": 0,
      "activeCalls": 0,
      "physicalRequests": 0,
      "receipts": []
    }
  },
  "running": {
    "status": 200,
    "body": {
      "v": 1,
      "instanceId": "chat-instance",
      "sessionId": "chat-session",
      "requestId": "phone-request",
      "binding": {
        "archiveId": "phone-archive",
        "controlRevision": 0,
        "historyAfterSeq": 0
      },
      "state": "running",
      "complete": false,
      "revision": 18,
      "gaps": [],
      "observedAdapterCalls": 1,
      "activeCalls": 0,
      "physicalRequests": 1,
      "receipts": [
        {
          "receiptId": "47b033ff-6a6a-4463-b02e-4a889aa69fd2",
          "callId": "4604550b-0d3d-4c25-85d2-d77ed26a7e1d",
          "revision": 16,
          "requestIds": [
            "phone-request"
          ],
          "provider": "chosen-provider",
          "model": "chosen-model",
          "phase": "finished",
          "observation": "fetch-invoked",
          "dispatched": true,
          "dispatchAtMs": 1795246360231,
          "handoffAtMs": 1795280000000,
          "physicalRequests": 1,
          "terminal": "complete",
          "complete": true,
          "httpStatus": 200,
          "errorCode": null,
          "usage": {
            "provider": "chosen-provider",
            "model": "chosen-model",
            "start_usage": {
              "input_tokens": 90,
              "cache_read_input_tokens": 3
            },
            "final_usage": {
              "output_tokens": 7,
              "original_extra": {
                "retained": true
              }
            },
            "start_event": "message_start",
            "final_event": "message_delta",
            "usage_semantics": "cumulative",
            "input_uncached": null,
            "input_cache_read": null,
            "input_cache_write": null,
            "output_tokens": 7,
            "stop_reason": "end_turn",
            "terminal": "complete",
            "complete": true,
            "http_status": 200
          }
        }
      ]
    }
  },
  "complete": {
    "status": 200,
    "body": {
      "v": 1,
      "instanceId": "chat-instance",
      "sessionId": "chat-session",
      "requestId": "phone-request",
      "binding": {
        "archiveId": "phone-archive",
        "controlRevision": 0,
        "historyAfterSeq": 0
      },
      "state": "settled",
      "complete": true,
      "revision": 19,
      "gaps": [],
      "observedAdapterCalls": 1,
      "activeCalls": 0,
      "physicalRequests": 1,
      "receipts": [
        {
          "receiptId": "47b033ff-6a6a-4463-b02e-4a889aa69fd2",
          "callId": "4604550b-0d3d-4c25-85d2-d77ed26a7e1d",
          "revision": 16,
          "requestIds": [
            "phone-request"
          ],
          "provider": "chosen-provider",
          "model": "chosen-model",
          "phase": "finished",
          "observation": "fetch-invoked",
          "dispatched": true,
          "dispatchAtMs": 1795246360231,
          "handoffAtMs": 1795280000000,
          "physicalRequests": 1,
          "terminal": "complete",
          "complete": true,
          "httpStatus": 200,
          "errorCode": null,
          "usage": {
            "provider": "chosen-provider",
            "model": "chosen-model",
            "start_usage": {
              "input_tokens": 90,
              "cache_read_input_tokens": 3
            },
            "final_usage": {
              "output_tokens": 7,
              "original_extra": {
                "retained": true
              }
            },
            "start_event": "message_start",
            "final_event": "message_delta",
            "usage_semantics": "cumulative",
            "input_uncached": null,
            "input_cache_read": null,
            "input_cache_write": null,
            "output_tokens": 7,
            "stop_reason": "end_turn",
            "terminal": "complete",
            "complete": true,
            "http_status": 200
          }
        }
      ]
    }
  },
  "instanceChanged": {
    "status": 200,
    "body": {
      "v": 1,
      "instanceId": "chat-instance",
      "sessionId": "chat-session",
      "requestId": "phone-request",
      "binding": null,
      "state": "unknown",
      "complete": false,
      "revision": 0,
      "gaps": [
        "instance-changed"
      ],
      "observedAdapterCalls": 0,
      "activeCalls": 0,
      "physicalRequests": null,
      "receipts": []
    }
  },
  "notRetained": {
    "status": 200,
    "body": {
      "v": 1,
      "instanceId": "chat-instance",
      "sessionId": "chat-session",
      "requestId": "evicted-request",
      "binding": null,
      "state": "unknown",
      "complete": false,
      "revision": 0,
      "gaps": [
        "not-retained"
      ],
      "observedAdapterCalls": 0,
      "activeCalls": 0,
      "physicalRequests": null,
      "receipts": []
    }
  },
  "forbidden": {
    "status": 403,
    "body": {
      "error": {
        "code": "companion/usage-forbidden",
        "message": "Companion usage observations require the host owner"
      }
    }
  },
  "incomplete": {
    "status": 200,
    "body": {
      "v": 1,
      "instanceId": "chat-instance",
      "sessionId": "chat-session",
      "requestId": "phone-request",
      "binding": {
        "archiveId": "phone-archive",
        "controlRevision": 0,
        "historyAfterSeq": 0
      },
      "state": "settled",
      "complete": true,
      "revision": 17,
      "gaps": [],
      "observedAdapterCalls": 1,
      "activeCalls": 0,
      "physicalRequests": 1,
      "receipts": [
        {
          "receiptId": "09685747-6cbb-4854-a8c1-0d99522a87d2",
          "callId": "7c58e5eb-dd37-48ee-ad8a-642117b0e060",
          "revision": 14,
          "requestIds": [
            "phone-request"
          ],
          "provider": "chosen-provider",
          "model": "chosen-model",
          "phase": "finished",
          "observation": "fetch-invoked",
          "dispatched": true,
          "dispatchAtMs": 1795246360291,
          "handoffAtMs": 1795280000000,
          "physicalRequests": 1,
          "terminal": "incomplete",
          "complete": false,
          "httpStatus": 200,
          "errorCode": "STREAM_CLOSED",
          "usage": {
            "provider": "chosen-provider",
            "model": "chosen-model",
            "start_usage": {
              "input_tokens": 90,
              "cache_read_input_tokens": 3
            },
            "final_usage": {
              "output_tokens": 7,
              "original_extra": {
                "retained": true
              }
            },
            "start_event": "message_start",
            "final_event": "message_delta",
            "usage_semantics": "cumulative",
            "input_uncached": null,
            "input_cache_read": null,
            "input_cache_write": null,
            "output_tokens": 7,
            "stop_reason": "end_turn",
            "terminal": "incomplete",
            "complete": false,
            "http_status": 200
          }
        }
      ]
    }
  },
  "preflight": {
    "status": 200,
    "body": {
      "v": 1,
      "instanceId": "chat-instance",
      "sessionId": "chat-session",
      "requestId": "phone-request",
      "binding": {
        "archiveId": "phone-archive",
        "controlRevision": 0,
        "historyAfterSeq": 0
      },
      "state": "settled",
      "complete": true,
      "revision": 9,
      "gaps": [],
      "observedAdapterCalls": 1,
      "activeCalls": 0,
      "physicalRequests": 0,
      "receipts": [
        {
          "receiptId": "cb857a41-2668-4237-bae5-5ec4fb398d61",
          "callId": "c08575a6-91f6-4403-bd9a-83815c7545fa",
          "revision": 6,
          "requestIds": [
            "phone-request"
          ],
          "provider": "chosen-provider",
          "model": "chosen-model",
          "phase": "finished",
          "observation": "preflight",
          "dispatched": false,
          "dispatchAtMs": null,
          "handoffAtMs": 1795280000000,
          "physicalRequests": 0,
          "terminal": "provider_error",
          "complete": false,
          "httpStatus": null,
          "errorCode": "MISSING_CREDENTIAL",
          "usage": {
            "provider": "chosen-provider",
            "model": "chosen-model",
            "start_usage": null,
            "final_usage": null,
            "start_event": null,
            "final_event": null,
            "usage_semantics": "cumulative",
            "input_uncached": null,
            "input_cache_read": null,
            "input_cache_write": null,
            "output_tokens": null,
            "stop_reason": null,
            "terminal": "provider_error",
            "complete": false,
            "http_status": null
          }
        }
      ]
    }
  },
  "generic": {
    "status": 200,
    "body": {
      "v": 1,
      "instanceId": "chat-instance",
      "sessionId": "chat-session",
      "requestId": "phone-request",
      "binding": {
        "archiveId": "phone-archive",
        "controlRevision": 0,
        "historyAfterSeq": 0
      },
      "state": "settled",
      "complete": false,
      "revision": 14,
      "gaps": [
        "physical-count-unknown"
      ],
      "observedAdapterCalls": 1,
      "activeCalls": 0,
      "physicalRequests": null,
      "receipts": [
        {
          "receiptId": "64057291-7792-4c58-9a3c-9591d3a7fd47",
          "callId": "33b62065-30e9-4387-8e1a-e8d070b7beb0",
          "revision": 11,
          "requestIds": [
            "phone-request"
          ],
          "provider": "chosen-piai",
          "model": "chosen-piai-model",
          "phase": "finished",
          "observation": "adapter-invoked",
          "dispatched": null,
          "dispatchAtMs": null,
          "handoffAtMs": 1795280000000,
          "physicalRequests": null,
          "terminal": "complete",
          "complete": true,
          "httpStatus": null,
          "errorCode": null,
          "usage": {
            "provider": "chosen-piai",
            "model": "chosen-piai-model",
            "start_usage": null,
            "final_usage": null,
            "start_event": null,
            "final_event": null,
            "usage_semantics": "unknown",
            "input_uncached": null,
            "input_cache_read": null,
            "input_cache_write": null,
            "output_tokens": null,
            "stop_reason": null,
            "terminal": "complete",
            "complete": true,
            "http_status": null,
            "runtime_normalized_usage": [
              {
                "inputTokens": 4,
                "outputTokens": 2,
                "totalTokens": 6
              }
            ],
            "runtime_normalized_usage_semantics": "runtime-normalized-events"
          }
        }
      ]
    }
  },
  "oldRoute": {
    "status": 404,
    "body": {
      "error": {
        "code": "companion/not-found",
        "message": "Companion route not found"
      }
    }
  }
}
''';

Map<String, Object?> _wire(String name) => Map<String, Object?>.from((jsonDecode(_hostWireJson) as Map)[name] as Map);
Map<String, Object?> _body(String name) => _wire(name)['body'] as Map<String, Object?>;
Map<String, Object?> _receipt(Map<String, Object?> body) => (body['receipts'] as List).first as Map<String, Object?>;
Map<String, Object?> _usage(Map<String, Object?> body) => _receipt(body)['usage'] as Map<String, Object?>;

class _Host {
  _Host._(this.server) {
    server.listen((request) async {
      paths.add(request.uri);
      methods.add(request.method);
      cookies.add(request.headers.value(HttpHeaders.cookieHeader));
      bodies.add(await utf8.decoder.bind(request).join());
      await answer(request);
    });
  }
  static Future<_Host> start() async => _Host._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  final HttpServer server;
  final paths = <Uri>[], methods = <String>[], cookies = <String?>[], bodies = <String>[];
  Map<String, Object?> wire = _wire('complete');
  late Future<void> Function(HttpRequest) answer = (request) async {
    request.response.statusCode = wire['status'] as int;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(wire['body']));
    await request.response.close();
  };
  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}');
  Future<void> close() async {
    await server.close(force: true);
  }
}

class _NoHttpCarrier extends DshCarrier {
  @override
  String get kind => 'synthetic-non-http';
  @override
  DshTracer? get tracer => null;
  @override
  Future<void> close() async {}
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      throw StateError('Usage must not call RPC');
  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw StateError('Usage must not open mux');
}

Future<CompanionChatUsageSnapshot?> _read(
  DshClient client, {
  String instanceId = 'chat-instance',
  String requestId = 'phone-request',
  String sessionId = 'chat-session',
}) => client.readCompanionChatUsage(instanceId: instanceId, sessionId: sessionId, requestId: requestId);

void main() {
  late _Host host;
  late DshClient client;
  setUp(() async {
    host = await _Host.start();
    client = DshClient(
      DshConnection(
        host.uri,
        hostHeader: host.uri.authority,
        cookie: DshCookie(name: 'dsh-auth-test', value: 'synthetic-cookie', authority: host.uri.authority),
      ),
    );
  });
  tearDown(() async {
    await client.close();
    await host.close();
  });

  test('actual authenticated GET preserves exact frozen identity and raw final missing components', () async {
    final result = (await _read(client))!, receipt = result.receipts.single;
    expect(host.methods, ['GET']);
    expect(host.paths.single.path, '/dsh-go/v1/companion/usage');
    expect(host.paths.single.queryParameters, {
      'instanceId': 'chat-instance',
      'sessionId': 'chat-session',
      'requestId': 'phone-request',
    });
    expect(host.bodies, ['']);
    expect(host.cookies.single, contains('dsh-auth-test=synthetic-cookie'));
    expect(result.toJson(), _body('complete'));
    expect(result.state, 'settled');
    expect(result.complete, isTrue);
    expect(result.binding!.archiveId, 'phone-archive');
    expect(result.binding!.controlRevision, 0);
    expect(result.physicalRequests, 1);
    expect(result.observedAdapterCalls, 1);
    expect(receipt.requestIds, ['phone-request']);
    expect(receipt.dispatched, isTrue);
    expect(receipt.dispatchAtMs, isA<int>());
    expect(receipt.physicalRequests, 1);
    expect(receipt.complete, isTrue);
    expect(receipt.usage['start_usage'], {'input_tokens': 90, 'cache_read_input_tokens': 3});
    expect(receipt.usage['final_usage'], {
      'output_tokens': 7,
      'original_extra': {'retained': true},
    });
    expect(receipt.usage['input_uncached'], isNull);
    expect(receipt.usage['input_cache_read'], isNull);
    expect(receipt.usage['input_cache_write'], isNull);
    expect(receipt.usage['output_tokens'], 7);
    expect(() => result.toJson()['complete'] = false, throwsUnsupportedError);
    expect(() => receipt.usage['output_tokens'] = 0, throwsUnsupportedError);
    expect(() => (receipt.usage['final_usage'] as Map)['output_tokens'] = 0, throwsUnsupportedError);
  });

  test(
    'generic receipt keeps original normalized observations separately with unknown physical dispatch and raw',
    () async {
      host.wire = _wire('generic');
      final result = (await _read(client))!, receipt = result.receipts.single;
      expect(result.toJson(), _body('generic'));
      expect(result.state, 'settled');
      expect(result.complete, isFalse);
      expect(result.physicalRequests, isNull);
      expect(result.gaps, ['physical-count-unknown']);
      expect(receipt.dispatched, isNull);
      expect(receipt.dispatchAtMs, isNull);
      expect(receipt.physicalRequests, isNull);
      expect(receipt.usage['input_uncached'], isNull);
      expect(receipt.usage['output_tokens'], isNull);
      expect(receipt.usage['start_usage'], isNull);
      expect(receipt.usage['final_usage'], isNull);
      expect(receipt.usage['runtime_normalized_usage'], [
        {'inputTokens': 4, 'outputTokens': 2, 'totalTokens': 6},
      ]);
      expect(receipt.usage['runtime_normalized_usage_semantics'], 'runtime-normalized-events');
    },
  );

  test(
    'provider final then EOF keeps raw known usage and distinguishes root coverage from response completion',
    () async {
      host.wire = _wire('incomplete');
      final result = (await _read(client))!, receipt = result.receipts.single;
      expect(result.complete, isTrue);
      expect(receipt.complete, isFalse);
      expect(receipt.terminal, 'incomplete');
      expect(receipt.errorCode, 'STREAM_CLOSED');
      expect(receipt.usage['output_tokens'], 7);
      expect(receipt.usage['input_uncached'], isNull);
      expect(receipt.usage['final_usage'], _usage(_body('incomplete'))['final_usage']);
    },
  );

  test('only actual preflight proof carries false and zero physical requests', () async {
    host.wire = _wire('preflight');
    final result = (await _read(client))!, receipt = result.receipts.single;
    expect(result.physicalRequests, 0);
    expect(receipt.dispatched, isFalse);
    expect(receipt.observation, 'preflight');
    expect(receipt.dispatchAtMs, isNull);
    expect(receipt.usage['output_tokens'], isNull);
  });

  for (final name in ['pending', 'running']) {
    test('captured $name root remains incomplete independently of a receipt terminal', () async {
      host.wire = _wire(name);
      final result = (await _read(client))!;
      expect(result.state, name);
      expect(result.complete, isFalse);
      expect(result.toJson(), _body(name));
    });
  }

  test(
    'restart unknown revision zero is accepted after a high revision without rewriting original delivery identity',
    () async {
      final prior = (await _read(client))!;
      expect(prior.revision, greaterThan(0));
      host.wire = _wire('instanceChanged');
      final unknown = (await _read(client, instanceId: 'previous-instance'))!;
      expect(unknown.state, 'unknown');
      expect(unknown.revision, 0);
      expect(unknown.instanceId, 'chat-instance');
      expect(unknown.gaps, ['instance-changed']);
      expect(unknown.physicalRequests, isNull);
      expect(unknown.binding, isNull);
      expect(unknown.receipts, isEmpty);
      expect(unknown.complete, isFalse);
      expect(
        host.paths.last.queryParameters['instanceId'],
        'previous-instance',
        reason: 'SDK must not rediscover and rebind',
      );
      expect(
        prior.receipts.single.usage['output_tokens'],
        7,
        reason: 'a separate unknown snapshot does not mutate prior evidence',
      );
    },
  );

  test('evicted identity is explicit unknown and is not converted to a free empty receipt', () async {
    host.wire = _wire('notRetained');
    final unknown = (await _read(client, requestId: 'evicted-request'))!;
    expect(unknown.state, 'unknown');
    expect(unknown.revision, 0);
    expect(unknown.gaps, ['not-retained']);
    expect(unknown.physicalRequests, isNull);
    expect(unknown.complete, isFalse);
  });

  test('actual original bridge namespace 404 returns null without a model or RPC fallback', () async {
    host.wire = _wire('oldRoute');
    expect(await _read(client), isNull);
    expect(host.methods, ['GET']);
  });

  test('non-HTTP carrier returns null without RPC or mux work', () async {
    final other = DshClient.withCarrier(_NoHttpCarrier());
    try {
      expect(await _read(other), isNull);
      expect(host.paths, isEmpty);
    } finally {
      await other.close();
    }
  });

  test('real prefixed owner refusal remains a remote error and is never treated as unclaimed route', () async {
    host.wire = _wire('forbidden');
    await expectLater(
      _read(client),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'companion/usage-forbidden')),
    );
    host.wire = {
      'status': 404,
      'body': {
        'error': {'code': 'companion/usage-unavailable'},
      },
    };
    await expectLater(
      _read(client),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'companion/usage-unavailable')),
    );
    expect(host.methods, ['GET', 'GET']);
  });

  test('redirects are not followed or retried', () async {
    host.answer = (request) async {
      request.response.statusCode = 302;
      request.response.headers.set(HttpHeaders.locationHeader, '/other');
      await request.response.close();
    };
    await expectLater(_read(client), throwsA(isA<DshHttpException>().having((e) => e.statusCode, 'status', 302)));
    expect(host.paths, hasLength(1));
  });

  test('malformed success is a protocol error with no retry or fallback', () async {
    host.answer = (request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{');
      await request.response.close();
    };
    await expectLater(_read(client), throwsA(isA<DshProtocolException>()));
    expect(host.paths, hasLength(1));
  });

  for (final name in ['instanceId', 'sessionId', 'requestId']) {
    test('a known receipt for a different $name is rejected', () async {
      final body = _body('complete');
      body[name] = 'other';
      host.wire = {'status': 200, 'body': body};
      await expectLater(_read(client), throwsA(isA<DshProtocolException>()));
      expect(host.paths, hasLength(1));
    });
  }

  test('Unicode identity is encoded exactly and does not widen the allowed HTTP query', () async {
    final body = _body('complete');
    body['requestId'] = 'phone🐋?/&';
    _receipt(body)['requestIds'] = ['phone🐋?/&'];
    host.wire = {'status': 200, 'body': body};
    expect((await _read(client, requestId: 'phone🐋?/&'))!.requestId, 'phone🐋?/&');
    expect(host.paths.single.queryParameters['requestId'], 'phone🐋?/&');
    expect(host.paths.single.queryParameters, hasLength(3));
  });

  test('invalid identity fails locally before HTTP', () async {
    for (final value in ['', 'x\n', String.fromCharCode(0xd800), List.filled(129, 'x').join()]) {
      await expectLater(_read(client, requestId: value), throwsArgumentError);
    }
    expect(host.paths, isEmpty);
  });

  final invalid = <String, void Function(Map<String, Object?>)>{
    'duplicate global receipt ID': (body) => (body['receipts'] as List).add(_receipt(body)),
    'receipt omits owning root': (body) => _receipt(body)['requestIds'] = ['different-root'],
    'receipt revision exceeds root': (body) => _receipt(body)['revision'] = (body['revision'] as int) + 1,
    'known fetch pretends unsent': (body) => _receipt(body)['dispatched'] = false,
    'raw missing input filled from start': (body) => _usage(body)['input_uncached'] = 90,
    'root physical total differs': (body) => body['physicalRequests'] = 2,
    'complete coverage with a gap': (body) => body['gaps'] = ['capacity'],
    'finished root with active receipt': (body) => _receipt(body)['phase'] = 'active',
    'unsafe component': (body) => _usage(body)['output_tokens'] = 9007199254740992,
    'usage model relabeled': (body) => _usage(body)['model'] = 'other-model',
    'unknown carries known receipts': (body) {
      body['state'] = 'unknown';
      body['complete'] = false;
      body['revision'] = 0;
    },
  };
  for (final entry in invalid.entries) {
    test('rejects inconsistent evidence: ${entry.key}', () {
      final body = _body('complete');
      entry.value(body);
      expect(() => CompanionChatUsageSnapshot.fromJson(body), throwsA(isA<DshProtocolException>()));
    });
  }

  test('generic normalized zeros cannot masquerade as known raw components', () {
    final body = _body('generic');
    _usage(body)['input_uncached'] = 0;
    expect(() => CompanionChatUsageSnapshot.fromJson(body), throwsA(isA<DshProtocolException>()));
  });

  test('actual route names and an unusual provider stop reason are metadata, not local provider allow-lists', () {
    final body = _body('complete'), name = List.filled(160, 'm').join();
    _receipt(body)['model'] = name;
    _usage(body)['model'] = name;
    _usage(body)['stop_reason'] = '';
    final snapshot = CompanionChatUsageSnapshot.fromJson(body);
    expect(snapshot.receipts.single.model, name);
    expect(snapshot.receipts.single.usage['stop_reason'], '');
  });

  test('same global physical receipt is legal in two root snapshots and retains shared ownership', () {
    final first = _body('complete');
    _receipt(first)['requestIds'] = ['phone-request', 'second-root'];
    final second = jsonDecode(jsonEncode(first)) as Map<String, Object?>;
    second['requestId'] = 'second-root';
    final a = CompanionChatUsageSnapshot.fromJson(first), b = CompanionChatUsageSnapshot.fromJson(second);
    expect(a.receipts.single.receiptId, b.receipts.single.receiptId);
    expect(a.receipts.single.callId, b.receipts.single.callId);
    expect(a.receipts.single.requestIds, ['phone-request', 'second-root']);
    expect(
      a.receipts.single.toJson(),
      b.receipts.single.toJson(),
      reason: 'SDK does not mint per-root duplicate billing identities',
    );
  });
}
