import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  TavernModelConfig config({bool deepseek = true, String? baseUrl, String? key = 'test-key'}) =>
      TavernModelConfig(apiKey: () async => key, deepseek: deepseek, baseUrl: baseUrl ?? 'https://api.deepseek.com');

  test('SSE handles every byte boundary, BOM, CRLF, comments and multi-line data', () async {
    final bytes = utf8.encode('\uFEFF: keepalive\r\ndata: {"text":\r\ndata: "你好🐋"}\r\n\r\ndata: [DONE]\r\n\r\n');
    final events = await decodeServerSentEvents(Stream.fromIterable(bytes.map((b) => [b]))).toList();
    expect(events, ['{"text":\n"你好🐋"}', '[DONE]']);
  });

  test('DeepSeek URL normalizes beta and generic services retain their API prefix', () {
    expect(TavernModelClient.endpoint(config()), Uri.parse('https://api.deepseek.com/beta/chat/completions'));
    expect(
      TavernModelClient.endpoint(config(baseUrl: 'https://example.test/v1/')),
      Uri.parse('https://example.test/beta/chat/completions'),
    );
    expect(
      TavernModelClient.endpoint(config(baseUrl: 'https://example.test/beta')),
      Uri.parse('https://example.test/beta/chat/completions'),
    );
    expect(
      TavernModelClient.endpoint(config(baseUrl: 'https://api.deepseek.com/v1/chat/completions')),
      Uri.parse('https://api.deepseek.com/beta/chat/completions'),
    );
    expect(
      TavernModelClient.endpoint(config(deepseek: false, baseUrl: 'http://localhost:9000/service/v1')),
      Uri.parse('http://localhost:9000/service/v1/chat/completions'),
    );
    expect(
      TavernModelClient.endpoint(config(deepseek: false, baseUrl: 'https://example.test/v1/chat/completions')),
      Uri.parse('https://example.test/v1/chat/completions'),
    );
    // Removing a fragment must preserve the service's query, including an
    // explicitly empty query, for both path construction and a complete URL.
    for (final row in const [
      (
        true,
        'https://example.test/v1?key=one%2Ftwo#client',
        'https://example.test/beta/chat/completions?key=one%2Ftwo',
      ),
      (false, 'http://localhost:9000/service/v1?#', 'http://localhost:9000/service/v1/chat/completions?'),
      (
        false,
        'https://example.test/v1/chat/completions?key=one%2Ftwo#client',
        'https://example.test/v1/chat/completions?key=one%2Ftwo',
      ),
    ]) {
      final endpoint = TavernModelClient.endpoint(config(deepseek: row.$1, baseUrl: row.$2));
      expect(endpoint, Uri.parse(row.$3));
      expect(endpoint.hasFragment, isFalse);
    }
  });

  test("an assistant message's reasoning goes to OpenRouter and is dropped for other generic services", () {
    final body = {
      'messages': [
        {'role': 'assistant', 'content': 'a', 'reasoning': 'r', 'reasoning_content': 'x'},
      ],
    };
    Map<String, Object?> sent(String url) =>
        (prepareModelRequestBody(config(deepseek: false, baseUrl: url), body)['messages']! as List).single
            as Map<String, Object?>;
    expect(sent('https://openrouter.ai/api/v1'), {'role': 'assistant', 'content': 'a', 'reasoning': 'r'});
    expect(sent('https://example.test/v1'), {'role': 'assistant', 'content': 'a'});
  });

  test('streams reasoning and text, then reads usage with empty choices', () async {
    late http.BaseRequest captured;
    final client = _Client((request) async {
      captured = request;
      final events = [
        {
          'choices': [
            {
              'index': 0,
              'delta': {'reasoning_content': '思考🐋'},
            },
          ],
        },
        {
          'choices': [
            {
              'index': 0,
              'delta': {'content': '你好'},
            },
          ],
        },
        {
          'choices': [
            {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
          ],
        },
        {
          'model': 'deepseek-flash',
          'choices': [],
          'usage': {'prompt_tokens': 100, 'prompt_cache_hit_tokens': 80, 'completion_tokens': 9},
        },
      ];
      return _sse(events);
    });
    final body = <String, Object?>{
      'messages': [
        {'role': 'user', 'content': '继续'},
        {'role': 'assistant', 'content': '她说：', 'prefix': true},
      ],
    };
    final settlements = <(ModelUsageReport?, bool)>[];
    final events = await TavernModelClient(
      clientFactory: () => client,
      onUsageSettled: (report, {required partial}) => settlements.add((report, partial)),
    ).generate(config: config(), body: body, cancellation: ModelCancellation()).toList();
    expect(settlements.single.$2, isFalse);
    expect(settlements.single.$1!.fields['completion_tokens'], containsPair('value', 9));
    expect(captured.url.path, '/beta/chat/completions');
    expect(captured.headers['Authorization'], 'Bearer test-key');
    final sent = jsonDecode(utf8.decode(await captured.finalize().toBytes())) as Map<String, dynamic>;
    expect((sent['messages'] as List<dynamic>).last, {'role': 'assistant', 'content': '她说：', 'prefix': true});
    expect(sent['thinking'], {'type': 'disabled'});
    expect(sent['model'], 'deepseek-flash');
    expect(body.containsKey('model'), isFalse);
    expect(events.whereType<ModelReasoning>().single.text, '思考🐋');
    expect(events.whereType<ModelText>().single.text, '你好');
    final usage = events.whereType<ModelUsage>().single.usage;
    expect(usage.promptTokens, 100);
    expect(usage.cacheHitTokens, 80);
    expect(usage.completionTokens, 9);
    expect(events.last, isA<ModelFinished>());
    expect(events.whereType<ModelFinished>(), hasLength(1));
    expect(client.closed, isTrue);
  });

  test('a generic non-streaming response reads cached_tokens without DeepSeek fields', () async {
    late Map<String, dynamic> sent;
    final client = _Client((request) async {
      sent = jsonDecode(utf8.decode(await request.finalize().toBytes())) as Map<String, dynamic>;
      final body = {
        'model': 'local-model',
        'choices': [
          {
            'message': {'content': '答复'},
            'finish_reason': 'stop',
          },
        ],
        'usage': {
          'prompt_tokens': 20,
          'completion_tokens': 2,
          'prompt_tokens_details': {'cached_tokens': 12},
        },
      };
      return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), 200);
    });
    final events = await TavernModelClient(
      clientFactory: () => client,
    ).generate(config: config(deepseek: false), body: {'stream': false}, cancellation: ModelCancellation()).toList();
    expect(sent.containsKey('thinking'), isFalse);
    expect(events.whereType<ModelText>().single.text, '答复');
    expect(events.whereType<ModelUsage>().single.usage.cacheHitTokens, 12);
  });

  for (final streaming in [false, true]) {
    test('cancel after the first delta stops remaining fields (stream=$streaming)', () async {
      final cancellation = ModelCancellation();
      final completion = <String, Object?>{
        'choices': [
          {
            streaming ? 'delta' : 'message': {'reasoning_content': 'first', 'content': 'must not appear'},
            'finish_reason': 'stop',
          },
        ],
        'usage': {'prompt_tokens': 3, 'completion_tokens': 2},
      };
      final client = _Client(
        (_) async => streaming
            ? _sse([completion])
            : http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(completion))), 200),
      );
      final observed = <ModelDelta>[];
      final future = TavernModelClient(clientFactory: () => client)
          .generate(config: config(), body: {'stream': streaming}, cancellation: cancellation)
          .forEach((event) {
            observed.add(event);
            cancellation.cancel();
          });
      await expectLater(
        future,
        throwsA(isA<TavernModelException>().having((error) => error.kind, 'kind', TavernFailure.cancelled)),
      );
      expect(observed, hasLength(1));
      expect(observed.single, isA<ModelReasoning>());
      expect(client.closed, isTrue);
    });
  }

  for (final testCase in [
    (401, '{"error":"bad key test-key"}', TavernFailure.badKey),
    (429, '{"error":"rate limit"}', TavernFailure.busy),
    (400, '{"error":{"code":"context_length_exceeded"}}', TavernFailure.contextTooLong),
    (503, 'unavailable', TavernFailure.server),
  ]) {
    test('maps HTTP ${testCase.$1} and removes the API key from details', () async {
      final client = _Client((_) async => http.StreamedResponse(Stream.value(utf8.encode(testCase.$2)), testCase.$1));
      final stream = TavernModelClient(
        clientFactory: () => client,
      ).generate(config: config(), body: {}, cancellation: ModelCancellation());
      await expectLater(
        stream.toList(),
        throwsA(
          isA<TavernModelException>()
              .having((error) => error.kind, 'kind', testCase.$3)
              .having((error) => error.detail.contains('test-key'), 'contains key', isFalse),
        ),
      );
      expect(client.closed, isTrue);
    });
  }

  test('an in-band API error fails and never emits a successful finish', () async {
    final client = _Client(
      (_) async => _sse([
        {
          'error': {'message': 'server failed'},
        },
      ]),
    );
    await expectLater(
      TavernModelClient(
        clientFactory: () => client,
      ).generate(config: config(), body: {}, cancellation: ModelCancellation()).toList(),
      throwsA(isA<TavernModelException>().having((error) => error.kind, 'kind', TavernFailure.server)),
    );
  });

  test('a cut-off stream keeps deltas but reports a network failure', () async {
    final client = _Client(
      (_) async => _sse([
        {
          'choices': [
            {
              'delta': {'content': '半句'},
            },
          ],
        },
      ], done: false),
    );
    final received = <ModelDelta>[];
    Object? failure;
    try {
      await for (final event in TavernModelClient(
        clientFactory: () => client,
      ).generate(config: config(), body: {}, cancellation: ModelCancellation())) {
        received.add(event);
      }
    } catch (error) {
      failure = error;
    }
    expect(received.whereType<ModelText>().single.text, '半句');
    expect(received.whereType<ModelFinished>(), isEmpty);
    expect(failure, isA<TavernModelException>().having((e) => e.kind, 'kind', TavernFailure.network));
  });

  test('missing key does not create a network client', () async {
    var created = false;
    final transport = TavernModelClient(
      clientFactory: () {
        created = true;
        throw StateError('must not create');
      },
    );
    await expectLater(
      transport.generate(config: config(key: null), body: {}, cancellation: ModelCancellation()).toList(),
      throwsA(isA<TavernModelException>().having((e) => e.kind, 'kind', TavernFailure.noKey)),
    );
    expect(created, isFalse);
  });

  test('stop while awaiting secure storage ends promptly without a request', () async {
    final key = Completer<String?>();
    final entered = Completer<void>();
    final cancellation = ModelCancellation();
    final pending = TavernModelClient()
        .generate(
          config: TavernModelConfig(
            apiKey: () {
              entered.complete();
              return key.future;
            },
          ),
          body: {},
          cancellation: cancellation,
        )
        .toList();
    final expectation = expectLater(
      pending,
      throwsA(isA<TavernModelException>().having((e) => e.kind, 'kind', TavernFailure.cancelled)),
    );
    await entered.future;
    cancellation.cancel();
    await expectation;
    key.complete('unused-test-key');
  });

  test('stop on an open response aborts only that request and closes its client', () async {
    final cancellation = ModelCancellation();
    final connected = Completer<void>();
    final response = StreamController<List<int>>(onListen: connected.complete);
    final client = _Client((request) async {
      unawaited(
        (request as http.AbortableRequest).abortTrigger!.then((_) async {
          response.addError(http.RequestAbortedException(request.url));
          await response.close();
        }),
      );
      return http.StreamedResponse(response.stream, 200);
    });
    final future = TavernModelClient(
      clientFactory: () => client,
    ).generate(config: config(), body: {}, cancellation: cancellation).toList();
    final expectation = expectLater(
      future,
      throwsA(isA<TavernModelException>().having((e) => e.kind, 'kind', TavernFailure.cancelled)),
    );
    await connected.future;
    cancellation.cancel();
    await expectation;
    expect(client.closed, isTrue);
  });
}

http.StreamedResponse _sse(List<Map<String, Object?>> events, {bool done = true}) {
  final text = '${events.map((e) => 'data: ${jsonEncode(e)}\r\n\r\n').join()}${done ? 'data: [DONE]\r\n\r\n' : ''}';
  return http.StreamedResponse(Stream.fromIterable(utf8.encode(text).map((byte) => [byte])), 200);
}

class _Client extends http.BaseClient {
  _Client(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => handler(request);

  @override
  void close() => closed = true;
}
