import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const _path = '/dsh-go/v1/companion/auxiliary';
const _session = 'full-companion-session';
const _request = 'phone-request-1';
const _instance = 'host-instance-1';
const _hostTime = 1795260000123;

// Captured from actual A02h routes by checks/A02d-wire-fixtures.mjs.
// oldRoute is the exact original da7980270 companion route response.
// Embed the literal payloads so these tests do not require Node or a runtime.
const _hostWireJson = r'''
{
  "forbidden": {
    "status": 403,
    "body": {
      "error": {
        "code": "companion/auxiliary-forbidden",
        "message": "Companion auxiliary transport requires the host owner"
      },
      "dispatched": false
    }
  },
  "busy": {
    "status": 409,
    "body": {
      "error": {
        "code": "companion/auxiliary-busy",
        "message": "Another companion auxiliary request is still active"
      },
      "dispatched": false
    }
  },
  "instanceChanged": {
    "status": 409,
    "body": {
      "error": {
        "code": "companion/auxiliary-instance-changed",
        "message": "The companion bridge restarted; do not resend an uncertain prior request"
      },
      "dispatched": null
    }
  },
  "requestUnknown": {
    "status": 404,
    "body": {
      "error": {
        "code": "companion/auxiliary-request-unknown",
        "message": "No receipt exists in this bridge instance"
      },
      "dispatched": null
    }
  },
  "requestUsed": {
    "status": 409,
    "body": {
      "error": {
        "code": "companion/auxiliary-request-used",
        "message": "This auxiliary request ID has already been used"
      },
      "dispatched": null,
      "receipt": {
        "v": 1,
        "instanceId": "73799137-8a0f-47ee-84e1-747c2be39347",
        "requestId": "request",
        "phase": "finished",
        "dispatched": true,
        "dispatchAtMs": 1795280000123,
        "finish": {
          "type": "finish",
          "requestId": "request",
          "dispatched": true,
          "dispatchAtMs": 1795280000123,
          "terminal": "complete",
          "complete": true,
          "stopReason": "end_turn",
          "httpStatus": 200,
          "usage": {
            "provider": "selected-provider",
            "model": "selected-model",
            "start_usage": {
              "input_tokens": 51,
              "output_tokens": 0,
              "cache_read_input_tokens": 99,
              "custom_field": {
                "retained": true
              }
            },
            "final_usage": {
              "output_tokens": 7
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
      }
    }
  },
  "requestConflict": {
    "status": 409,
    "body": {
      "error": {
        "code": "companion/auxiliary-request-conflict",
        "message": "This auxiliary request ID has already been used"
      },
      "dispatched": null,
      "receipt": {
        "v": 1,
        "instanceId": "73799137-8a0f-47ee-84e1-747c2be39347",
        "requestId": "request",
        "phase": "finished",
        "dispatched": true,
        "dispatchAtMs": 1795280000123,
        "finish": {
          "type": "finish",
          "requestId": "request",
          "dispatched": true,
          "dispatchAtMs": 1795280000123,
          "terminal": "complete",
          "complete": true,
          "stopReason": "end_turn",
          "httpStatus": 200,
          "usage": {
            "provider": "selected-provider",
            "model": "selected-model",
            "start_usage": {
              "input_tokens": 51,
              "output_tokens": 0,
              "cache_read_input_tokens": 99,
              "custom_field": {
                "retained": true
              }
            },
            "final_usage": {
              "output_tokens": 7
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
      }
    }
  },
  "sessionUnavailable": {
    "status": 200,
    "body": [
      {
        "type": "accepted",
        "instanceId": "73799137-8a0f-47ee-84e1-747c2be39347",
        "provider": "selected-provider",
        "model": "selected-model",
        "requestId": "missing-session"
      },
      {
        "type": "finish",
        "requestId": "missing-session",
        "dispatched": false,
        "dispatchAtMs": null,
        "terminal": "preflight_error",
        "complete": false,
        "stopReason": null,
        "httpStatus": null,
        "usage": {
          "provider": "selected-provider",
          "model": "selected-model",
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
          "terminal": "preflight_error",
          "complete": false,
          "http_status": null,
          "runtime_normalized_usage": [],
          "runtime_normalized_usage_semantics": "runtime-normalized-events",
          "host_adapter_handoff_at_ms": null,
          "runtime_finish_kind": null
        },
        "error": {
          "code": "companion/auxiliary-session-unavailable"
        }
      }
    ]
  },
  "modelUnavailable": {
    "status": 200,
    "body": [
      {
        "type": "accepted",
        "instanceId": "73799137-8a0f-47ee-84e1-747c2be39347",
        "provider": "selected-provider",
        "model": "selected-model",
        "requestId": "missing-model"
      },
      {
        "type": "finish",
        "requestId": "missing-model",
        "dispatched": false,
        "dispatchAtMs": null,
        "terminal": "preflight_error",
        "complete": false,
        "stopReason": null,
        "httpStatus": null,
        "usage": {
          "provider": "selected-provider",
          "model": "selected-model",
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
          "terminal": "preflight_error",
          "complete": false,
          "http_status": null,
          "runtime_normalized_usage": [],
          "runtime_normalized_usage_semantics": "runtime-normalized-events",
          "host_adapter_handoff_at_ms": null,
          "runtime_finish_kind": null
        },
        "error": {
          "code": "companion/auxiliary-model-unavailable"
        }
      }
    ]
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

Map<String, Object?> _capability({bool generic = false, bool supported = true}) => {
  'v': 1,
  'instanceId': _instance,
  'provider': generic ? 'selected-provider' : 'deepseek',
  'model': generic ? 'selected-model' : 'deepseek-flash',
  'supported': supported,
  if (supported)
    'capability': {
      'physicalDispatch': generic ? 'unknown' : 'fetch-invoked',
      'rawUsage': generic ? 'unavailable' : 'deepseek-messages-cumulative',
      'maxPhysicalRequests': generic ? null : 1,
      'noTools': true,
    },
  if (!supported) 'reason': 'adapter-call-unavailable',
};

Map<String, Object?> _accepted(Map<String, Object?> cap) => {
  'type': 'accepted',
  'requestId': _request,
  'instanceId': cap['instanceId'],
  'provider': cap['provider'],
  'model': cap['model'],
};

Map<String, Object?> _dispatch() => {
  'type': 'dispatch',
  'requestId': _request,
  'atMs': _hostTime,
  'boundary': 'fetch-invoked',
};

Map<String, Object?> _usage(Map<String, Object?> cap, {bool generic = false, bool complete = true}) => {
  'provider': cap['provider'],
  'model': cap['model'],
  'start_usage': generic ? null : {'input_tokens': 90, 'cache_read_input_tokens': 3},
  'final_usage': generic ? null : {'input_tokens': 7, 'cache_read_input_tokens': 3, 'output_tokens': 5},
  'start_event': generic ? null : 'message_start',
  'final_event': generic ? null : 'message_delta',
  'usage_semantics': generic ? 'unknown' : 'cumulative',
  'input_uncached': generic ? null : 7,
  'input_cache_read': generic ? null : 3,
  'input_cache_write': null,
  'output_tokens': generic ? null : 5,
  'stop_reason': generic ? null : 'end_turn',
  'terminal': complete ? 'complete' : 'preflight_error',
  'complete': complete,
  'http_status': generic ? null : 200,
  if (generic) ...{
    'runtime_normalized_usage': [
      {'inputTokens': 10, 'outputTokens': 5},
    ],
    'runtime_normalized_usage_semantics': 'runtime-normalized-events',
    'host_adapter_handoff_at_ms': _hostTime,
    'runtime_finish_kind': 'stop',
  },
};

Map<String, Object?> _finish(Map<String, Object?> cap, {bool? dispatched = true, bool generic = false}) => {
  'type': 'finish',
  'requestId': _request,
  'dispatched': dispatched,
  'dispatchAtMs': dispatched == true ? _hostTime : null,
  'terminal': 'complete',
  'complete': true,
  'stopReason': generic ? null : 'end_turn',
  'httpStatus': generic ? null : 200,
  'usage': _usage(cap, generic: generic),
};

Future<void> _json(HttpRequest request, Object? value, {int status = 200}) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(value));
  await request.response.close();
}

Future<void> _frames(HttpRequest request, List<Map<String, Object?>> values) async {
  request.response.headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
  for (final value in values) {
    request.response.write('${jsonEncode(value)}\n');
  }
  await request.response.close();
}

class _Host {
  _Host._(this.server) {
    server.listen((request) async {
      paths.add(request.uri);
      cookies.add(request.headers.value(HttpHeaders.cookieHeader));
      hosts.add(request.headers.value(HttpHeaders.hostHeader));
      final text = await utf8.decoder.bind(request).join();
      bodies.add(text.isEmpty ? null : jsonDecode(text) as Map<String, Object?>);
      await answer(request);
    });
  }

  static Future<_Host> start() async => _Host._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer server;
  final paths = <Uri>[];
  final cookies = <String?>[];
  final hosts = <String?>[];
  final bodies = <Map<String, Object?>?>[];
  Map<String, Object?> capability = _capability();
  late Future<void> Function(HttpRequest request) answer = (request) => _json(request, capability);
  Uri get baseUri => Uri.parse('http://127.0.0.1:${server.port}');
  Future<void> close() async {
    await server.close(force: true);
  }
}

class _Probe {
  final events = <String>[];
  final usage = <Map<String, Object?>>[];
  void uncertain() => events.add('uncertain');
  void sent() => events.add('sent');
  void received(Map<String, Object?> value) {
    events.add('usage');
    usage.add(value);
  }
}

/// The real HttpClient performs every exchange; this observes its opening
/// boundary so the durable callback order is checked before any socket work.
class _ObservedHttpClient implements HttpClient {
  final delegate = HttpClient();
  void Function(String method)? onOpen;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    onOpen?.call(method);
    return delegate.openUrl(method, url);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<CompanionAuxiliaryResult> _call(
  DshClient client,
  CompanionAuxiliaryCapability cap,
  _Probe probe, {
  DshHttpAbort? abort,
  String input = 'synthetic conversation batch',
  String requestId = _request,
  String kind = 'extract',
  String system = 'Extract a JSON proposal from the given batch.',
}) => client.callCompanionAuxiliary(
  cap,
  requestId: requestId,
  kind: kind,
  system: system,
  input: input,
  maxTokens: 1400,
  abort: abort ?? DshHttpAbort(),
  onDispatchUncertain: probe.uncertain,
  onSent: probe.sent,
  onUsage: probe.received,
);

void main() {
  late _Host host;
  late DshClient client;
  late _ObservedHttpClient http;
  setUp(() async {
    host = await _Host.start();
    http = _ObservedHttpClient();
    client = DshClient(
      DshConnection(
        host.baseUri,
        httpClient: http,
        hostHeader: host.baseUri.authority,
        cookie: DshCookie(name: 'dsh-auth-test', value: 'fixture-cookie', authority: host.baseUri.authority),
      ),
    );
  });
  tearDown(() async {
    await client.close();
    http.delegate.close(force: true);
    await host.close();
  });

  test('actual HTTP uses one frozen selection, cookie and exact no-tools DTO', () async {
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    http.onOpen = (method) {
      expect(method, 'POST');
      expect(probe.events, ['uncertain']);
      probe.events.add('http-open');
    };
    host.answer = (request) {
      expect(probe.events, ['uncertain', 'http-open']);
      return _frames(request, [
        _accepted(host.capability),
        _dispatch(),
        {
          'type': 'usage',
          'requestId': _request,
          'event': 'message_start',
          'semantics': 'cumulative',
          'raw': {'input_tokens': 90, 'cache_read_input_tokens': 3},
        },
        {'type': 'text', 'requestId': _request, 'text': '{"items":[]}'},
        _finish(host.capability),
      ]);
    };
    final result = await _call(client, cap, probe);
    expect(result.text, '{"items":[]}');
    expect(result.complete, isTrue);
    expect(result.dispatched, isTrue);
    expect(probe.events, ['uncertain', 'http-open', 'sent', 'usage']);
    expect(probe.usage.single, {..._usage(host.capability), 'host_dispatch_at_ms': _hostTime});
    expect(probe.usage.single['input_uncached'], 7);
    expect(probe.usage.single['input_cache_write'], isNull);
    expect(host.paths.map((uri) => uri.path), [_path, _path]);
    expect(host.paths.first.queryParameters, {'sessionId': _session});
    expect(host.cookies, everyElement('dsh-auth-test=fixture-cookie'));
    expect(host.hosts, everyElement(host.baseUri.authority));
    expect(host.bodies.last, {
      'v': 1,
      'instanceId': _instance,
      'requestId': _request,
      'sessionId': _session,
      'provider': 'deepseek',
      'model': 'deepseek-flash',
      'kind': 'extract',
      'system': 'Extract a JSON proposal from the given batch.',
      'input': 'synthetic conversation batch',
      'maxTokens': 1400,
    });
    http.onOpen = null;
    const selected = ModelSelection(provider: 'screen-provider', model: 'screen-model', reasoningEffort: 'off');
    host.capability = {
      ..._capability(),
      'kind': 'screen',
      'provider': selected.provider,
      'model': selected.model,
      'reasoningEffort': selected.reasoningEffort,
      'capability': {...(_capability()['capability']! as Map), 'transientImage': 'jpeg-512-inline'},
    };
    host.answer = (request) => _json(request, host.capability);
    final screen = (await client.readCompanionScreenCapability(selected))!;
    expect(screen.supported, isTrue);
    expect(host.paths.last.queryParameters, {
      'kind': 'screen',
      'provider': selected.provider,
      'model': selected.model,
      'reasoningEffort': 'off',
    });
    final pixels = Uint8List.fromList(base64Decode('/9j/wAALCAABAAEBAREA/9k='));
    final image = CompanionScreenImage.fromNative({
      'mime_type': 'image/jpeg',
      'width': 1,
      'height': 1,
      'bytes': pixels,
    })!;
    expect(
      CompanionScreenImage.fromNative({'mime_type': 'image/jpeg', 'width': 513, 'height': 1, 'bytes': pixels}),
      isNull,
    );
    pixels.fillRange(0, pixels.length, 0);
    final screenProbe = _Probe();
    http.onOpen = (method) {
      expect(method, 'POST');
      expect(screenProbe.events, ['uncertain']);
      screenProbe.events.add('http-open');
    };
    host.answer = (request) => _frames(request, [
      _accepted(host.capability),
      _dispatch(),
      {'type': 'text', 'requestId': _request, 'text': '{"scene":"reading"}'},
      _finish(host.capability),
    ]);
    final observed = await client.callCompanionScreen(
      screen,
      requestId: _request,
      system: 'Classify external screen data.',
      input: 'Synthetic accessibility text.',
      image: image,
      maxTokens: 220,
      abort: DshHttpAbort(),
      onDispatchUncertain: screenProbe.uncertain,
      onSent: screenProbe.sent,
      onUsage: screenProbe.received,
    );
    expect(observed.terminal, 'complete');
    expect(observed.complete, isTrue);
    expect(screenProbe.events, ['uncertain', 'http-open', 'sent', 'usage']);
    expect(screenProbe.usage.single['provider'], selected.provider);
    expect(screenProbe.usage.single['input_uncached'], 7);
    expect(host.paths.last.path, '$_path/screen');
    expect(host.bodies.last, {
      'v': 1,
      'instanceId': _instance,
      'requestId': _request,
      'kind': 'screen',
      'provider': selected.provider,
      'model': selected.model,
      'reasoningEffort': 'off',
      'system': 'Classify external screen data.',
      'input': 'Synthetic accessibility text.',
      'maxTokens': 220,
      'image': {'mediaType': 'image/jpeg', 'width': 1, 'height': 1, 'data': '/9j/wAALCAABAAEBAREA/9k='},
    });
    expect(
      host.paths,
      hasLength(4),
      reason: 'one discovery and one POST per independent attempt, with no Session route',
    );
    expect(host.cookies, everyElement('dsh-auth-test=fixture-cookie'));
    expect(host.hosts, everyElement(host.baseUri.authority));
  });

  test('generic callable route keeps dispatch and raw unknown, normalized separate', () async {
    host.capability = _capability(generic: true);
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    host.answer = (request) => _frames(request, [
      _accepted(host.capability),
      {
        'type': 'runtime-usage',
        'requestId': _request,
        'semantics': 'runtime-normalized',
        'usage': {'inputTokens': 10, 'outputTokens': 5},
      },
      {'type': 'text', 'requestId': _request, 'text': '{"items":[]}'},
      _finish(host.capability, generic: true, dispatched: null),
    ]);
    final result = await _call(client, cap, probe);
    expect(cap.supported, isTrue);
    expect(cap.maxPhysicalRequests, isNull);
    expect(result.dispatched, isNull);
    expect(result.complete, isTrue);
    expect(probe.events, ['uncertain', 'usage']);
    expect(result.usage['final_usage'], isNull);
    expect(result.usage['input_uncached'], isNull);
    expect(result.usage['runtime_normalized_usage'], [
      {'inputTokens': 10, 'outputTokens': 5},
    ]);
    expect(host.bodies.last?['provider'], 'selected-provider');
    expect(host.bodies.last?['model'], 'selected-model');

    // The private image route can prove fetch while its adapter still exposes
    // only runtime-normalized usage. It does not become DeepSeek raw usage.
    const selected = ModelSelection(provider: 'selected-provider', model: 'selected-model');
    host.capability = {
      ..._capability(generic: true),
      'kind': 'screen',
      'capability': {
        ...(_capability(generic: true)['capability']! as Map),
        'physicalDispatch': 'fetch-invoked',
        'maxPhysicalRequests': 1,
        'transientImage': 'jpeg-512-inline',
      },
    };
    host.answer = (request) => _json(request, host.capability);
    final screen = (await client.readCompanionScreenCapability(selected))!;
    expect(screen.supported, isTrue);
    final image = CompanionScreenImage.fromNative({
      'mime_type': 'image/jpeg',
      'width': 1,
      'height': 1,
      'bytes': base64Decode('/9j/wAALCAABAAEBAREA/9k='),
    })!;
    const normalized = {
      'inputTokens': 10,
      'outputTokens': 5,
      'totalTokens': 15,
      'reported': {'inputTokens': 10, 'outputTokens': 5, 'cacheReadTokens': 0, 'cacheWriteTokens': 0},
    };
    final imageUsage = {
      ..._usage(host.capability, generic: true),
      'http_status': 200,
      'host_adapter_handoff_at_ms': null,
      'runtime_normalized_usage': [normalized],
    };
    final imageProbe = _Probe();
    host.answer = (request) => _frames(request, [
      _accepted(host.capability),
      _dispatch(),
      {'type': 'runtime-usage', 'requestId': _request, 'semantics': 'runtime-normalized', 'usage': normalized},
      {'type': 'text', 'requestId': _request, 'text': '{"scene":"reading"}'},
      {..._finish(host.capability, generic: true), 'httpStatus': 200, 'usage': imageUsage},
    ]);
    final observed = await client.callCompanionScreen(
      screen,
      requestId: _request,
      system: 'Classify external screen data.',
      input: 'Synthetic accessibility text.',
      image: image,
      maxTokens: 220,
      abort: DshHttpAbort(),
      onDispatchUncertain: imageProbe.uncertain,
      onSent: imageProbe.sent,
      onUsage: imageProbe.received,
    );
    expect(observed.complete, isTrue);
    expect(observed.dispatched, isTrue);
    expect(observed.httpStatus, 200);
    expect(observed.text, '{"scene":"reading"}');
    expect(imageProbe.events, ['uncertain', 'sent', 'usage']);
    expect(imageProbe.usage.single, {...imageUsage, 'host_dispatch_at_ms': _hostTime});
    expect(observed.usage['start_usage'], isNull);
    expect(observed.usage['final_usage'], isNull);
    expect(observed.usage['input_uncached'], isNull);
    expect(observed.usage['output_tokens'], isNull);
    expect(observed.usage['usage_semantics'], 'unknown');
    expect(observed.usage['runtime_normalized_usage'], [normalized]);
    expect(host.paths.map((uri) => uri.path), [_path, _path, _path, '$_path/screen']);
    expect(host.bodies.last!['provider'], selected.provider);
    expect(host.bodies.last!['model'], selected.model);
    expect(host.bodies.last!.containsKey('sessionId'), isFalse);
    expect(host.bodies.last!['image'], image.toJson());
  });

  test('followup uses the same frozen selected provider and returns its exact NDJSON receipt', () async {
    host.capability = _capability(generic: true);
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    const proposal = '{"action":"line","text":"周四的修琴，今天想聊聊吗？"}';
    final input = jsonEncode({
      'card': {'text': '我周四去修琴'},
      'persona': '说话自然、简短。',
      'invitation': {
        'message_id': 'invite-1',
        'source_rev': 1,
        'said_at_utc': '2026-11-16T04:00:00Z',
        'offset_minutes': 480,
        'quote': '我周四去修琴，周五可以问我修琴的进展',
      },
      'support': <Object?>[],
      'now_utc': '2026-11-20T01:00:00Z',
      'offset_minutes': 480,
    });
    host.answer = (request) => _frames(request, [
      _accepted(host.capability),
      {'type': 'text', 'requestId': _request, 'text': proposal},
      _finish(host.capability, generic: true, dispatched: null),
    ]);
    final result = await _call(
      client,
      cap,
      probe,
      kind: 'followup',
      system: companionMemoryFollowupPrompt,
      input: input,
    );
    expect(result.text, proposal);
    expect(result.complete, isTrue);
    expect(result.dispatched, isNull, reason: 'generic adapter dispatch is still unobserved');
    expect(probe.events, ['uncertain', 'usage']);
    expect(probe.usage.single, {..._usage(host.capability, generic: true), 'host_dispatch_at_ms': null});
    expect(host.bodies.last!['kind'], 'followup');
    expect(host.bodies.last!['provider'], cap.provider);
    expect(host.bodies.last!['model'], cap.model);
    expect(host.bodies.last!['system'], companionMemoryFollowupPrompt);
    expect(host.bodies.last!['input'], input);
    expect(host.bodies.last!.keys, isNot(contains('tools')));
    expect(host.paths.map((uri) => uri.path), [_path, _path]);
  });

  test('an older host rejecting followup proves unsent without a fallback POST', () async {
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    // Literal validation error from the owner B bridge, whose kind allowlist
    // has only extract/consolidate. This is an explicit current preflight.
    host.answer = (request) => _json(request, {
      'error': {'code': 'companion/auxiliary-invalid-request', 'message': 'Invalid companion auxiliary request'},
      'dispatched': false,
    }, status: 400);
    await expectLater(
      _call(client, cap, probe, kind: 'followup', system: companionMemoryFollowupPrompt),
      throwsA(
        isA<CompanionAuxiliaryFailure>()
            .having((error) => error.code, 'code', 'companion/auxiliary-invalid-request')
            .having((error) => error.notSent, 'notSent', true)
            .having((error) => error.terminal, 'terminal', 'preflight_error'),
      ),
    );
    expect(probe.events, ['uncertain', 'usage']);
    expect(host.paths, hasLength(2));
    expect(host.bodies.last!['kind'], 'followup');
  });

  test('partial final usage survives a missing finish without adding the start', () async {
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    host.answer = (request) => _frames(request, [
      _accepted(host.capability),
      _dispatch(),
      {
        'type': 'usage',
        'requestId': _request,
        'event': 'message_start',
        'semantics': 'cumulative',
        'raw': {'input_tokens': 90, 'cache_read_input_tokens': 3},
      },
      {
        'type': 'usage',
        'requestId': _request,
        'event': 'message_delta',
        'semantics': 'cumulative',
        'raw': {'input_tokens': 7, 'output_tokens': 5},
      },
    ]);
    await expectLater(
      _call(client, cap, probe),
      throwsA(isA<CompanionAuxiliaryFailure>().having((e) => e.notSent, 'notSent', false)),
    );
    expect(probe.events, ['uncertain', 'sent', 'usage']);
    expect(probe.usage.single['input_uncached'], 7);
    expect(probe.usage.single['input_cache_read'], isNull);
    expect(probe.usage.single['input_cache_write'], isNull);
    expect(probe.usage.single['complete'], isFalse);
    expect(probe.usage.single['proxy_finish_observed'], isFalse);
    expect(probe.usage.single['host_dispatch_at_ms'], _hostTime);
    expect(host.bodies.whereType<Map<String, Object?>>(), hasLength(1));
  });

  test('accepted then disconnect without dispatch stays unknown and never retries', () async {
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    host.answer = (request) => _frames(request, [_accepted(host.capability)]);
    await expectLater(
      _call(client, cap, probe),
      throwsA(isA<CompanionAuxiliaryFailure>().having((e) => e.notSent, 'notSent', false)),
    );
    expect(probe.events, ['uncertain', 'usage']);
    expect(probe.usage.single['host_dispatch_at_ms'], isNull);
    expect(host.paths, hasLength(2));
    host.capability = {
      ..._capability(generic: true),
      'kind': 'screen',
      'capability': {
        ...(_capability(generic: true)['capability']! as Map),
        'physicalDispatch': 'fetch-invoked',
        'maxPhysicalRequests': 1,
        'transientImage': 'jpeg-512-inline',
      },
    };
    host.answer = (request) => _json(request, host.capability);
    final screen = (await client.readCompanionScreenCapability(
      const ModelSelection(provider: 'selected-provider', model: 'selected-model'),
    ))!;
    final image = CompanionScreenImage.fromNative({
      'mime_type': 'image/jpeg',
      'width': 1,
      'height': 1,
      'bytes': base64Decode('/9j/wAALCAABAAEBAREA/9k='),
    })!;
    final imageProbe = _Probe();
    host.answer = (request) => _frames(request, [_accepted(host.capability)]);
    await expectLater(
      client.callCompanionScreen(
        screen,
        requestId: _request,
        system: 'Classify screen data.',
        input: 'External text.',
        image: image,
        maxTokens: 220,
        abort: DshHttpAbort(),
        onDispatchUncertain: imageProbe.uncertain,
        onSent: imageProbe.sent,
        onUsage: imageProbe.received,
      ),
      throwsA(isA<CompanionAuxiliaryFailure>().having((e) => e.notSent, 'notSent', false)),
    );
    expect(imageProbe.events, ['uncertain', 'usage']);
    expect(imageProbe.usage.single['host_dispatch_at_ms'], isNull);
    expect(imageProbe.usage.single['final_usage'], isNull);
    expect(imageProbe.usage.single['input_uncached'], isNull);
    expect(imageProbe.usage.single['complete'], isFalse);
    expect(imageProbe.usage.single['proxy_finish_observed'], isFalse);
    expect(host.paths, hasLength(4), reason: 'no repeated image POST or automatic text fallback');
    expect(host.paths.last.path, '$_path/screen');
  });

  test('explicit current preflight false is a result, never an inferred timeout', () async {
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    final usage = {
      ..._usage(host.capability, generic: true, complete: false),
      'runtime_normalized_usage': <Map<String, Object?>>[],
      'host_adapter_handoff_at_ms': null,
      'runtime_finish_kind': null,
    };
    host.answer = (request) => _frames(request, [
      _accepted(host.capability),
      {
        'type': 'finish',
        'requestId': _request,
        'dispatched': false,
        'dispatchAtMs': null,
        'terminal': 'preflight_error',
        'complete': false,
        'stopReason': null,
        'httpStatus': null,
        'usage': usage,
        'error': {'code': 'INVALID_CREDENTIAL'},
      },
    ]);
    final result = await _call(client, cap, probe);
    expect(result.dispatched, isFalse);
    expect(result.errorCode, 'INVALID_CREDENTIAL');
    expect(probe.events, ['uncertain', 'usage']);
  });

  for (final name in ['instanceChanged', 'requestUsed', 'requestConflict', 'requestUnknown']) {
    for (final forceFalse in [false, true]) {
      test('actual $name ${forceFalse ? "with adversarial false" : "with null"} retains the reservation', () async {
        final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
        final probe = _Probe();
        final wire = _wire(name);
        final body = Map<String, Object?>.from(wire['body']! as Map);
        final code = (body['error']! as Map)['code'];
        // Only this explicit fault variant changes the captured wire payload.
        if (forceFalse) body['dispatched'] = false;
        host.answer = (request) => _json(request, body, status: wire['status']! as int);
        await expectLater(
          _call(client, cap, probe),
          throwsA(
            isA<CompanionAuxiliaryFailure>()
                .having((e) => e.code, 'raw wire code', code)
                .having((e) => e.notSent, 'notSent', false),
          ),
        );
        expect(probe.events, ['uncertain', 'usage']);
        expect(probe.usage.single['host_dispatch_at_ms'], isNull);
        expect(probe.usage.single['output_tokens'], isNull);
        expect(host.paths, hasLength(2));
      });
    }
  }

  for (final name in ['forbidden', 'busy']) {
    test('actual $name preflight false can release without replay', () async {
      final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
      final probe = _Probe();
      final wire = _wire(name);
      final code = ((wire['body']! as Map)['error']! as Map)['code'];
      host.answer = (request) => _json(request, wire['body'], status: wire['status']! as int);
      await expectLater(
        _call(client, cap, probe),
        throwsA(
          isA<CompanionAuxiliaryFailure>()
              .having((e) => e.code, 'raw wire code', code)
              .having((e) => e.notSent, 'notSent', true),
        ),
      );
      expect(probe.events, ['uncertain', 'usage']);
      expect(host.paths, hasLength(2));
    });
  }

  test('429 status variant of the actual busy payload can release', () async {
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    // The captured A02h busy status is 409. This is an explicit status variant.
    host.answer = (request) => _json(request, _wire('busy')['body'], status: 429);
    await expectLater(
      _call(client, cap, probe),
      throwsA(
        isA<CompanionAuxiliaryFailure>()
            .having((e) => e.code, 'raw wire code', 'companion/auxiliary-busy')
            .having((e) => e.notSent, 'notSent', true),
      ),
    );
    expect(probe.events, ['uncertain', 'usage']);
    expect(host.paths, hasLength(2));
  });

  test('an unclaimed bare auxiliary code cannot establish Host preflight proof', () async {
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    host.answer = (request) => _json(request, {
      'error': {'code': 'auxiliary-forbidden'},
      'dispatched': false,
    }, status: 403);
    await expectLater(
      _call(client, cap, probe),
      throwsA(
        isA<CompanionAuxiliaryFailure>()
            .having((e) => e.code, 'unmodified code', 'auxiliary-forbidden')
            .having((e) => e.notSent, 'notSent', false),
      ),
    );
    expect(probe.events, ['uncertain', 'usage']);
  });

  for (final name in ['sessionUnavailable', 'modelUnavailable']) {
    test('actual accepted then $name preserves the qualified finish code and usage', () async {
      final wire = _wire(name);
      final frames = (wire['body']! as List).map((value) => Map<String, Object?>.from(value as Map)).toList();
      host.capability = {..._capability(generic: true), 'instanceId': frames.first['instanceId']};
      final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
      final probe = _Probe();
      host.answer = (request) => _frames(request, frames);
      final result = await _call(client, cap, probe, requestId: frames.first['requestId']! as String);
      expect(result.dispatched, isFalse);
      expect(result.complete, isFalse);
      expect(result.errorCode, (frames.last['error']! as Map)['code']);
      expect(result.httpStatus, isNull);
      expect(probe.events, ['uncertain', 'usage']);
      expect(probe.usage.single, {
        ...Map<String, Object?>.from(frames.last['usage']! as Map),
        'host_dispatch_at_ms': null,
      });
    });
  }

  test('POST redirects are not followed and do not prove unsent', () async {
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    host.answer = (request) async {
      request.response
        ..statusCode = 307
        ..headers.set('location', '/leak');
      await request.response.close();
    };
    await expectLater(
      _call(client, cap, probe),
      throwsA(isA<CompanionAuxiliaryFailure>().having((e) => e.notSent, 'notSent', false)),
    );
    expect(host.paths.map((uri) => uri.path), [_path, _path]);
  });

  test('local cancellation and oversized input do not hand off or record usage', () async {
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    for (final cancelled in [true, false]) {
      final probe = _Probe();
      final abort = DshHttpAbort();
      if (cancelled) abort.abort();
      await expectLater(
        _call(client, cap, probe, abort: abort, input: cancelled ? 'batch' : 'x' * 65536),
        throwsA(isA<CompanionAuxiliaryFailure>().having((e) => e.notSent, 'notSent', true)),
      );
      expect(probe.events, isEmpty);
    }
    expect(host.paths, hasLength(1));
  });

  test('failed durable uncertain callback prevents opening the model POST', () async {
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    await expectLater(
      client.callCompanionAuxiliary(
        cap,
        requestId: _request,
        kind: 'extract',
        system: 'system',
        input: 'batch',
        maxTokens: 1400,
        abort: DshHttpAbort(),
        onDispatchUncertain: () => throw StateError('reservation retired'),
        onSent: probe.sent,
        onUsage: probe.received,
      ),
      throwsStateError,
    );
    expect(probe.events, isEmpty);
    expect(host.paths, hasLength(1));
  });

  test('capability cannot be transplanted to another client owner', () async {
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final other = DshClient(DshConnection(host.baseUri));
    addTearDown(other.close);
    final probe = _Probe();
    await expectLater(
      _call(other, cap, probe),
      throwsA(isA<CompanionAuxiliaryFailure>().having((e) => e.notSent, 'notSent', true)),
    );
    expect(probe.events, isEmpty);
    expect(host.paths, hasLength(1));
  });

  test('no callable adapter is explicit unsupported; no POST is attempted', () async {
    host.capability = _capability(supported: false);
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    expect(cap.supported, isFalse);
    await expectLater(_call(client, cap, probe), throwsA(isA<CompanionAuxiliaryFailure>()));
    expect(probe.events, isEmpty);
    expect(host.paths, hasLength(1));
    host.capability = {...host.capability, 'kind': 'screen'};
    const selected = ModelSelection(provider: 'deepseek', model: 'deepseek-flash');
    final screen = (await client.readCompanionScreenCapability(selected))!;
    expect(screen.supported, isFalse);
    final image = CompanionScreenImage.fromNative({
      'mime_type': 'image/jpeg',
      'width': 1,
      'height': 1,
      'bytes': base64Decode('/9j/wAALCAABAAEBAREA/9k='),
    })!;
    await expectLater(
      client.callCompanionScreen(
        screen,
        requestId: _request,
        system: 'Classify screen data.',
        input: 'Text.',
        image: image,
        maxTokens: 220,
        abort: DshHttpAbort(),
        onDispatchUncertain: probe.uncertain,
        onSent: probe.sent,
        onUsage: probe.received,
      ),
      throwsA(isA<CompanionAuxiliaryFailure>().having((e) => e.notSent, 'notSent', true)),
    );
    expect(probe.events, isEmpty);
    expect(host.paths, hasLength(2));
    expect(host.bodies, everyElement(isNull));

    // Allowing unavailable raw usage must not admit an image route whose
    // physical dispatch is still unknown, even when its other fields match.
    host.capability = {
      ..._capability(),
      'kind': 'screen',
      'capability': {
        ...(_capability()['capability']! as Map),
        'rawUsage': 'unavailable',
        'physicalDispatch': 'unknown',
        'transientImage': 'jpeg-512-inline',
      },
    };
    await expectLater(client.readCompanionScreenCapability(selected), throwsA(isA<DshProtocolException>()));
    expect(probe.events, isEmpty);
    expect(host.paths, hasLength(3));
    expect(host.bodies, everyElement(isNull));
  });

  test('an older unclaimed route returns null without a fallback request', () async {
    host.answer = (request) => _json(request, {}, status: 404);
    expect(await client.readCompanionAuxiliaryCapability(_session), isNull);
    expect(host.paths, hasLength(1));
    expect(host.bodies.single, isNull);
  });

  test('original bridge companion/not-found is an absent route, not an auxiliary error', () async {
    final wire = _wire('oldRoute');
    host.answer = (request) => _json(request, wire['body'], status: wire['status']! as int);
    expect(await client.readCompanionAuxiliaryCapability(_session), isNull);
    expect(host.paths, hasLength(1));
    expect(host.bodies.single, isNull);
  });

  test('claimed auxiliary 404 remains an error rather than old-Host detection', () async {
    host.answer = (request) => _json(request, {
      'error': {'code': 'companion/auxiliary-invalid-request'},
      'dispatched': false,
    }, status: 404);
    await expectLater(
      client.readCompanionAuxiliaryCapability(_session),
      throwsA(
        isA<CompanionAuxiliaryFailure>()
            .having((e) => e.httpStatus, 'status', 404)
            .having((e) => e.code, 'code', 'companion/auxiliary-invalid-request'),
      ),
    );
    expect(host.paths, hasLength(1));
  });

  test('byte-split UTF8 and NDJSON still produce a single exact finish receipt', () async {
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    host.answer = (request) async {
      request.response.headers.contentType = ContentType('application', 'x-ndjson');
      final bytes = utf8.encode(
        [
          _accepted(host.capability),
          _dispatch(),
          {'type': 'text', 'requestId': _request, 'text': '记忆🙂'},
          _finish(host.capability),
        ].map((frame) => '${jsonEncode(frame)}\n').join(),
      );
      for (final byte in bytes) {
        request.response.add([byte]);
        await request.response.flush();
      }
      await request.response.close();
    };
    final result = await _call(client, cap, probe);
    expect(result.text, '记忆🙂');
    expect(probe.events, ['uncertain', 'sent', 'usage']);
  });

  for (final fault in ['wrong-instance', 'wrong-request', 'no-newline', 'bad-utf8', 'false-after-dispatch']) {
    test('$fault cannot settle as notSent or return a proposal', () async {
      final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
      final probe = _Probe();
      host.answer = (request) async {
        request.response.headers.contentType = ContentType('application', 'x-ndjson');
        final accepted = _accepted(host.capability);
        if (fault == 'wrong-instance') accepted['instanceId'] = 'new-host-generation';
        request.response.write('${jsonEncode(accepted)}\n');
        final finish = _finish(host.capability);
        if (fault == 'wrong-request') finish['requestId'] = 'another-request';
        if (fault == 'false-after-dispatch') {
          request.response.write('${jsonEncode(_dispatch())}\n');
          finish['dispatched'] = false;
          finish['dispatchAtMs'] = null;
        }
        if (fault == 'bad-utf8') {
          request.response.add([0xff, 10]);
        } else {
          request.response.write('${jsonEncode(finish)}${fault == 'no-newline' ? '' : '\n'}');
        }
        await request.response.close();
      };
      await expectLater(
        _call(client, cap, probe),
        throwsA(isA<CompanionAuxiliaryFailure>().having((e) => e.notSent, 'notSent', false)),
      );
      expect(probe.usage, hasLength(1));
      expect(host.paths, hasLength(2));
    });
  }

  test('abort after handoff retains unknown and cancels this exchange only', () async {
    final cap = (await client.readCompanionAuxiliaryCapability(_session))!;
    final probe = _Probe();
    final accepted = Completer<void>();
    final finish = Completer<void>();
    final abort = DshHttpAbort();
    host.answer = (request) async {
      request.response.headers.contentType = ContentType('application', 'x-ndjson');
      request.response.write('${jsonEncode(_accepted(host.capability))}\n');
      await request.response.flush();
      accepted.complete();
      await finish.future;
      try {
        await request.response.close();
      } on HttpException {
        // The caller owns the abort.
      } on SocketException {
        // The caller owns the abort.
      }
    };
    final expected = expectLater(
      _call(client, cap, probe, abort: abort),
      throwsA(isA<CompanionAuxiliaryFailure>().having((e) => e.notSent, 'notSent', false)),
    );
    await accepted.future;
    abort.abort();
    await expected;
    finish.complete();
    expect(probe.events, ['uncertain', 'usage']);
    expect(host.paths, hasLength(2));
    host.answer = (request) => _json(request, host.capability);
    expect(await client.readCompanionAuxiliaryCapability(_session), isNotNull);
  });
}
