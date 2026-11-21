import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:dsh_app/companion/companion_host_memory_transport.dart';
import 'package:dsh_app/companion/companion_memory_worker.dart';

const _path = '/dsh-go/v1/companion/auxiliary';
const _time = 1795260000123;

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

class _Host {
  _Host._(this.server, {required this.generic}) {
    client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      if (request.method == 'GET') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'v': 1,
            'instanceId': 'host-generation',
            'provider': provider,
            'model': model,
            'supported': true,
            'capability': {
              'physicalDispatch': generic ? 'unknown' : 'fetch-invoked',
              'rawUsage': generic ? 'unavailable' : 'deepseek-messages-cumulative',
              'maxPhysicalRequests': generic ? null : 1,
              'noTools': true,
            },
          }),
        );
      } else {
        expect(request.uri.path, _path);
        posts.add(jsonDecode(body) as Map<String, Object?>);
        onPost?.call();
        final wire = wireReply;
        if (wire == null) {
          request.response.headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
          for (final value in frames) {
            request.response.write('${jsonEncode(value)}\n');
          }
        } else {
          request.response.statusCode = wire['status']! as int;
          final payload = wire['body'];
          if (payload is List) {
            request.response.headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
            for (final value in payload) {
              // Rebind only identities for the worker's freshly generated ID
              // and this HTTP fixture's capability. Error/status/usage values
              // otherwise remain exactly as the real A02h route emitted them.
              final frame = Map<String, Object?>.from(value as Map);
              frame['requestId'] = posts.last['requestId'];
              if (frame['type'] == 'accepted') {
                frame['instanceId'] = 'host-generation';
                frame['provider'] = provider;
                frame['model'] = model;
              }
              final usage = frame['usage'];
              if (usage is Map) {
                frame['usage'] = {...Map<String, Object?>.from(usage), 'provider': provider, 'model': model};
              }
              request.response.write('${jsonEncode(frame)}\n');
            }
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode(payload));
          }
        }
      }
      await request.response.close();
    });
  }

  static Future<_Host> start({bool generic = false}) async =>
      _Host._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), generic: generic);

  final HttpServer server;
  final bool generic;
  late final DshClient client;
  final posts = <Map<String, Object?>>[];
  List<Map<String, Object?>> frames = [];
  Map<String, Object?>? wireReply;
  void Function()? onPost;
  String get provider => generic ? 'selected-other-provider' : 'deepseek';
  String get model => generic ? 'selected-other-model' : 'deepseek-flash';

  Map<String, Object?> get accepted => {
    'type': 'accepted',
    'requestId': 'request-1',
    'instanceId': 'host-generation',
    'provider': provider,
    'model': model,
  };

  Map<String, Object?> finish({
    bool? dispatched,
    String terminal = 'complete',
    bool complete = true,
    String? code,
    int? status,
  }) => {
    'type': 'finish',
    'requestId': 'request-1',
    'dispatched': dispatched,
    'dispatchAtMs': dispatched == true ? _time : null,
    'terminal': terminal,
    'complete': complete,
    'stopReason': null,
    'httpStatus': status,
    if (code != null) 'error': {'code': code},
    'usage': {
      'provider': provider,
      'model': model,
      'start_usage': null,
      'final_usage': null,
      'start_event': null,
      'final_event': null,
      'usage_semantics': 'unknown',
      'input_uncached': null,
      'input_cache_read': null,
      'input_cache_write': null,
      'output_tokens': null,
      'stop_reason': null,
      'terminal': terminal,
      'complete': complete,
      'http_status': status,
      if (generic) ...{
        'runtime_normalized_usage': [
          {'inputTokens': 10, 'outputTokens': 5},
        ],
        'runtime_normalized_usage_semantics': 'runtime-normalized-events',
      },
    },
  };

  Future<CompanionHostMemoryTransport> transport() async => CompanionHostMemoryTransport(
    client: client,
    capability: (await client.readCompanionAuxiliaryCapability('full-session'))!,
  );

  Future<void> close() async {
    await client.close();
    await server.close(force: true);
  }
}

class _Probe {
  final events = <String>[];
  final receipts = <Map<String, Object?>>[];
  final cancelled = Completer<void>();

  Future<CompanionAuxiliaryReply> call(CompanionMemoryTransport transport, {String category = 'extract'}) =>
      transport.call(
        requestId: 'request-1',
        category: category,
        system: 'Synthetic instruction.',
        input: 'Synthetic batch.',
        maxTokens: 1400,
        cancelled: cancelled.future,
        onDispatchUncertain: () => events.add('uncertain'),
        onSent: () => events.add('sent'),
        onUsage: (usage) {
          events.add('usage');
          receipts.add(usage);
        },
      );

  void close() {
    if (!cancelled.isCompleted) cancelled.complete();
  }
}

void main() {
  for (final rejected in [false, true]) {
    test(
      'B03 full followup ${rejected ? "old-host rejection is silent" : "uses the real auxiliary HTTP and ledger"}',
      () async {
        final host = await _Host.start();
        addTearDown(host.close);
        final store = CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => _time);
        final route = await host.transport();
        final worker = CompanionMemoryWorker(
          store: store,
          transport: () => route,
          nowMilliseconds: () => _time,
          estimateTokens: (text) => text.runes.length,
        );
        addTearDown(() async {
          await worker.stop();
          store.close();
        });
        const raw = '今天去修琴，今天可以问我琴修好没。';
        store.submitMessage(
          id: 'full-invite',
          sessionId: 'full-session',
          text: raw,
          saidAtUtc: _time,
          offsetMinutes: 0,
        );
        final batch = store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
        final proposal = parseExtractionProposal(
          jsonEncode({
            'schema_version': 2,
            'batch_id': batch.id,
            'covered_message_ids': ['full-invite'],
            'completion': 'complete',
            'operations': [
              {
                'op': 'create',
                'kind': 'episode',
                'text': '今天去修琴',
                'keywords': ['修琴'],
                'evidence': [
                  {'message_id': 'full-invite', 'quote': raw},
                ],
                'followup': {
                  'local_date': DateTime.fromMillisecondsSinceEpoch(
                    _time,
                    isUtc: true,
                  ).toIso8601String().substring(0, 10),
                  'precision': 'day',
                  'wording': '今天可以问我琴修好没',
                  'basis': 'explicit_invitation',
                },
              },
            ],
          }),
          batch,
        );
        expect(store.commitExtraction(batch, proposal), isTrue);
        final captured = store.nextFollowup(nowMs: _time)!;
        host.onPost = () {
          final sent = host.posts.last;
          final id = sent['requestId'];
          expect(store.requests().single['state'], 'interrupted', reason: 'persist uncertainty before actual HTTP');
          expect(sent['kind'], 'followup');
          expect(sent['maxTokens'], 128);
          expect(sent['system'], companionMemoryFollowupPrompt);
          expect(sent.containsKey('messages'), isFalse);
          expect(sent.containsKey('tools'), isFalse);
          final input = jsonDecode(sent['input'] as String) as Map;
          expect(input['persona'], '鲸鱼娘，说话自然简短。');
          expect(input['card'], {'text': '今天去修琴'});
          expect(input['invitation'], {
            'message_id': 'full-invite',
            'source_rev': 1,
            'said_at_utc': DateTime.fromMillisecondsSinceEpoch(_time, isUtc: true).toIso8601String(),
            'offset_minutes': 0,
            'quote': raw,
          });
          expect(input['support'], isEmpty);
          if (rejected) {
            host.wireReply = {
              'status': 400,
              'body': {
                'error': {'code': 'companion/auxiliary-invalid-request'},
                'dispatched': false,
              },
            };
          } else {
            final finish = host.finish(dispatched: true);
            (finish['usage'] as Map<String, Object?>).addAll({
              'final_usage': {
                'input_tokens': 120,
                'cache_read_input_tokens': 0,
                'cache_creation_input_tokens': 0,
                'output_tokens': 12,
              },
              'input_uncached': 120,
              'input_cache_read': 0,
              'input_cache_write': 0,
              'output_tokens': 12,
              'final_event': 'message_delta',
              'usage_semantics': 'cumulative',
            });
            host.frames = [
              {...host.accepted, 'requestId': id},
              {'type': 'dispatch', 'requestId': id, 'boundary': 'fetch-invoked', 'atMs': _time},
              {'type': 'text', 'requestId': id, 'text': '{"action":"line","text":"那把琴修好了吗？"}'},
              {...finish, 'requestId': id},
            ];
          }
        };
        final line = await worker.followup(captured, persona: '鲸鱼娘，说话自然简短。', offsetMinutes: 0, isCurrent: () => true);
        expect(line, rejected ? isNull : '那把琴修好了吗？');
        expect(host.posts, hasLength(1), reason: 'no chat fallback or retry');
        final receipt = store.requests().single;
        expect(receipt['category'], 'followup');
        expect(receipt['state'], rejected ? 'released' : 'finished');
        if (!rejected) {
          expect((receipt['raw_usage']! as Map)['final_usage'], containsPair('output_tokens', 12));
        }
        expect(store.followups().single['state'], 'pending', reason: 'HTTP completion is not a shown question');
      },
    );
  }

  test('the organize ledger category uses the actual consolidate host wire kind', () async {
    final host = await _Host.start(generic: true);
    addTearDown(host.close);
    final probe = _Probe();
    addTearDown(probe.close);
    final transport = await host.transport();
    host.frames = [host.accepted, host.finish()];
    expect((await probe.call(transport, category: 'organize')).complete, isTrue);
    expect(host.posts.single['kind'], 'consolidate');
    expect(probe.events, ['uncertain', 'usage']);
  });

  test('selected generic provider can complete with unknown dispatch and raw usage', () async {
    final host = await _Host.start(generic: true);
    addTearDown(host.close);
    final probe = _Probe();
    addTearDown(probe.close);
    final transport = await host.transport();
    host.frames = [
      host.accepted,
      {'type': 'text', 'requestId': 'request-1', 'text': '{"items":[]}'},
      host.finish(),
    ];
    final result = await probe.call(transport);
    expect(transport.configured, isTrue);
    expect(transport.provider, 'selected-other-provider');
    expect(transport.model, 'selected-other-model');
    expect(result.complete, isTrue);
    expect(result.text, '{"items":[]}');
    expect(probe.events, ['uncertain', 'usage']);
    expect(probe.receipts.single['input_uncached'], isNull);
    expect(probe.receipts.single['runtime_normalized_usage'], [
      {'inputTokens': 10, 'outputTokens': 5},
    ]);
    expect(host.posts.single['provider'], 'selected-other-provider');
  });

  test('explicit bad credential before dispatch releases with a configuration error', () async {
    final host = await _Host.start();
    addTearDown(host.close);
    final probe = _Probe();
    addTearDown(probe.close);
    final transport = await host.transport();
    host.frames = [
      host.accepted,
      host.finish(dispatched: false, terminal: 'preflight_error', complete: false, code: 'INVALID_CREDENTIAL'),
    ];
    await expectLater(
      probe.call(transport),
      throwsA(
        isA<CompanionAuxiliaryError>()
            .having((e) => e.configuration, 'configuration', true)
            .having((e) => e.notSent, 'notSent', true),
      ),
    );
    expect(probe.events, ['uncertain', 'usage']);
    expect(host.posts, hasLength(1));
  });

  test('provider HTTP 401 after fetch is configuration failure with budget retained', () async {
    final host = await _Host.start();
    addTearDown(host.close);
    final probe = _Probe();
    addTearDown(probe.close);
    final transport = await host.transport();
    host.frames = [
      host.accepted,
      {'type': 'dispatch', 'requestId': 'request-1', 'boundary': 'fetch-invoked', 'atMs': _time},
      host.finish(dispatched: true, terminal: 'http_error', complete: false, code: 'AUTH', status: 401),
    ];
    await expectLater(
      probe.call(transport),
      throwsA(
        isA<CompanionAuxiliaryError>()
            .having((e) => e.configuration, 'configuration', true)
            .having((e) => e.notSent, 'notSent', false),
      ),
    );
    expect(probe.events, ['uncertain', 'sent', 'usage']);
    expect(probe.receipts.single['host_dispatch_at_ms'], _time);
    expect(host.posts, hasLength(1));
  });

  test('complete max-token answer reaches the common invalid-proposal path', () async {
    final host = await _Host.start(generic: true);
    addTearDown(host.close);
    final probe = _Probe();
    addTearDown(probe.close);
    final transport = await host.transport();
    host.frames = [host.accepted, host.finish(terminal: 'max_tokens')];
    final reply = await probe.call(transport);
    expect(reply.complete, isTrue);
    expect(reply.terminal, 'max_tokens');
    expect(probe.events, ['uncertain', 'usage']);
  });

  test('missing finish is notSent false and cannot become an empty valid proposal', () async {
    final host = await _Host.start(generic: true);
    addTearDown(host.close);
    final probe = _Probe();
    addTearDown(probe.close);
    final transport = await host.transport();
    host.frames = [host.accepted];
    await expectLater(
      probe.call(transport),
      throwsA(
        isA<CompanionAuxiliaryError>()
            .having((e) => e.notSent, 'notSent', false)
            .having((e) => e.terminal, 'terminal', 'incomplete'),
      ),
    );
    expect(probe.events, ['uncertain', 'usage']);
    expect(probe.receipts.single['proxy_finish_observed'], isFalse);
    expect(host.posts, hasLength(1));
  });

  for (final name in [
    'forbidden',
    'busy',
    'busy429',
    'instanceChanged',
    'requestUsed',
    'requestConflict',
    'requestUnknown',
    'sessionUnavailable',
    'modelUnavailable',
  ]) {
    final uncertain = const {'instanceChanged', 'requestUsed', 'requestConflict', 'requestUnknown'}.contains(name);
    for (final forceFalse in uncertain ? [false, true] : [false]) {
      test('$name${forceFalse ? " with adversarial false" : ""} crosses SDK/App/worker into the real ledger', () async {
        final host = await _Host.start(generic: true);
        addTearDown(host.close);
        final wire = _wire(name == 'busy429' ? 'busy' : name);
        // A02h emits busy=409. 429 is a deliberately labeled status variant.
        if (name == 'busy429') wire['status'] = 429;
        if (forceFalse) (wire['body']! as Map)['dispatched'] = false;
        host.wireReply = wire;
        final route = await host.transport();
        final db = sqlite3.openInMemory();
        final store = CompanionMemoryStore(db, nowMilliseconds: () => _time);
        final worker = CompanionMemoryWorker(
          store: store,
          transport: () => route,
          nowMilliseconds: () => _time,
          estimateTokens: (text) => text.runes.length,
        );
        addTearDown(() async {
          await worker.stop();
          store.close();
        });
        store.submitMessage(
          id: 'u1',
          sessionId: 'full-session',
          text: '我的咖啡不加糖。',
          saidAtUtc: _time,
          offsetMinutes: 480,
        );
        host.onPost = () {
          final request = store.requests().single;
          expect(request['uncertain_at_ms'], _time, reason: 'durable before HTTP reaches the Host');
          expect(request['state'], 'interrupted');
          expect(request['sent_at_ms'], isNull);
        };
        final configuration = const {
          'forbidden',
          'requestUnknown',
          'sessionUnavailable',
          'modelUnavailable',
        }.contains(name);
        expect(
          await worker.extract(forceTail: true),
          configuration ? CompanionMemoryWork.configuration : CompanionMemoryWork.waiting,
        );
        final receipt = store.requests().single;
        expect(receipt['state'], uncertain ? 'interrupted' : 'released');
        expect(receipt['terminal'], uncertain ? 'dispatch_unknown' : 'not_sent');
        expect(receipt['sent_at_ms'], isNull);
        expect(receipt['uncertain_at_ms'], _time);
        final raw = receipt['raw_usage']! as Map;
        expect(raw['host_dispatch_at_ms'], isNull);
        expect(raw['output_tokens'], isNull, reason: 'a nested prior-ID receipt is not this attempt');
        expect(raw['complete'], isFalse);
        final source = db.select('SELECT state,reason,format_failures FROM memory_events').single;
        expect(source['state'], 'pending');
        expect(source['reason'], configuration ? 'configuration' : 'network');
        expect(source['format_failures'], 0);
        expect(store.archive['cursor_seq'], 0);
        expect(host.posts, hasLength(1), reason: 'no replay or automatic fallback');
        // Exactly 3000 new output tokens fit only if the prior preflight is
        // proven unsent. An uncertain attempt retains its 800-token hold.
        final next = store.reserveRequest(
          category: 'extract',
          provider: route.provider,
          model: route.model,
          inputTokens: 1,
          outputTokens: 3000,
        );
        expect(next, uncertain ? isNull : isNotNull);
      });
    }
  }
}
