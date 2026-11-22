import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

const _png =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aE1cAAAAASUVORK5CYII=';
const _tool = <String, Object?>{
  'type': 'function',
  'function': {
    'name': 'look',
    'parameters': {'type': 'object', 'properties': <String, Object?>{}, 'required': <Object?>[]},
  },
};

void main() {
  test(
    'Helper custom include-body yields to nonempty stops and retains fallback tools when none were offered',
    () async {
      final h = await generationFixture();
      final actor = await h.card('Custom precedence');
      final context = await h.context(await h.emptyChat(actor), characterId: actor);
      for (final stop in [false, true]) {
        await h.engine.setSettings({
          'stops': stop ? ['actual-stop'] : <String>[],
        });
        final response = h.reply('A');
        final generation = await h.bridge.generate(
          context.id,
          TavernHelperGenerateRequest.fromJson({
            'user_input': 'Q',
            'custom_api': {
              'source': 'custom',
              'custom_include_body': {
                'stop': ['included-stop'],
                'tools': [_tool],
                'tool_choice': 'none',
              },
            },
          }),
        );
        final wire = await generationRequest(generation, response);
        final result = await generation.result;
        expect(wire.body['stop'], [stop ? 'actual-stop' : 'included-stop']);
        expect(wire.body['tools'], [_tool]);
        expect(wire.body['tool_choice'], 'none');
        expect(result.toHelperValue(), 'A');
      }
    },
  );

  test(
    'Helper custom API consumes proxy, headers, body, images, tools and schema without changing the connection',
    () async {
      final h = await generationFixture();
      final recorder = _Recorder();
      h.model = TavernModelClient(clientFactory: () => _RecordingPeer(recorder));
      await h.reopen();
      await h.engine.setPreset(ChatPreset({...scriptPreset().raw, 'new_chat_prompt': '', 'send_if_empty': ''}));
      final host = _HelperHost()
        ..proxy = const TavernHelperProxy(url: ' https://proxy.invalid/custom/// ', key: 'proxy-secret');
      h.bridge.attachHost(host);
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'custom-helper'));
      recorder.responses.add(
        _jsonResponse({
          'role': 'assistant',
          'content': 'answer',
          'reasoning_content': 'thought',
          'tool_calls': [
            {
              'id': 'call_one',
              'type': 'function',
              'function': {
                'name': 'look',
                'arguments': {'x': 1},
              },
              'thought_signature': 'call-signature',
            },
          ],
        }, reason: 'tool_calls'),
      );
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'user_input': 'question',
          'image': [_png, 'https://image.invalid/two.png'],
          'ordered_prompts': ['chat_history', 'user_input'],
          'overrides': {
            'chat_history': {
              'with_depth_entries': false,
              'prompts': [
                {'role': 'user', 'content': 'old', 'image': _png},
              ],
            },
          },
          'custom_api': {
            'proxy_preset': ' Named proxy ',
            'apiurl': 'https://ignored.invalid/v1',
            'key': 'ignored-secret',
            'source': 'custom',
            'model': 'requested-model',
            'temperature': 1,
            'max_tokens': 'unset',
            'frequency_penalty': 0.2,
            'top_p': 'same_as_preset',
            'custom_include_headers': {'Authorization': 'Explicit fixture secret', 'X-Fixture': 42},
            'custom_include_body': {
              'model': 'body-model',
              'nested': {'keep': true},
              'literal.key': 'remove',
            },
            'custom_exclude_body': ['model', 'nested.keep', 'literal.key'],
          },
          'tools': [_tool],
          'tool_choice': {
            'type': 'function',
            'function': {'name': 'look'},
          },
          'json_schema': {
            'name': 'structured',
            'value': {'type': 'object'},
          },
        }),
      );
      final result = await generation.result;
      final wire = recorder.requests.single;
      expect(wire.url.toString(), 'https://proxy.invalid/custom/chat/completions');
      expect(wire.headers['authorization'], 'Explicit fixture secret');
      expect(wire.headers['x-fixture'], '42');
      expect(host.proxies, ['Named proxy']);
      expect(host.images, ['https://image.invalid/two.png']);
      expect(wire.body.containsKey('temperature'), isFalse);
      expect(wire.body.containsKey('max_tokens'), isFalse);
      expect(
        wire.body.containsKey('model'),
        isFalse,
        reason: 'Final transport must not reinsert an explicitly excluded field.',
      );
      expect(wire.body['nested'], {'keep': true}, reason: 'Exclude is a top-level literal-key operation.');
      expect(wire.body.containsKey('literal.key'), isFalse);
      expect(wire.body['frequency_penalty'], 0.2);
      expect(wire.body['tools'], [_tool]);
      expect(wire.body['tool_choice'], {
        'type': 'function',
        'function': {'name': 'look'},
      });
      expect(wire.body['response_format'], {
        'type': 'json_schema',
        'json_schema': {
          'name': 'structured',
          'schema': {'type': 'object'},
          'strict': true,
        },
      });
      final messages = (wire.body['messages']! as List<Object?>).cast<Map<String, Object?>>();
      expect((messages[0]['content']! as List<Object?>), [
        {'type': 'text', 'text': 'old'},
        {
          'type': 'image_url',
          'image_url': {'url': _png, 'detail': 'low'},
        },
      ]);
      expect((messages[1]['content']! as List<Object?>).length, 3);
      expect(result.toHelperValue(), {
        'content': 'answer',
        'reasoning': 'thought',
        'tool_calls': [
          {
            'id': 'call_one',
            'type': 'function',
            'function': {'name': 'look', 'arguments': '{"x":1}'},
            'thought_signature': 'call-signature',
          },
        ],
      });
      expect(h.keyReads, 0);

      final ordinary = await h.bridge.generateRaw(
        context.id,
        TavernScriptRawRequest(
          stream: false,
          orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'native')],
        ),
      );
      await ordinary.result;
      final native = recorder.requests.last;
      expect(native.url.toString(), 'https://p2-script.invalid/v1/chat/completions');
      expect(native.headers['authorization'], 'Bearer script-fixture-key');
      expect(native.body['model'], 'p2-script-model');
      expect(native.body.containsKey('tools'), isFalse);
      expect(native.headers.containsKey('x-fixture'), isFalse);
    },
  );

  test(
    'Helper DeepSeek explicit base keeps its path, forces reasoning, and converts tool/schema wire fields',
    () async {
      final h = await generationFixture();
      final recorder = _Recorder();
      h.model = TavernModelClient(clientFactory: () => _RecordingPeer(recorder));
      await h.reopen();
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'deepseek-helper'));
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'user_input': 'Q',
          'ordered_prompts': ['user_input'],
          'should_return_reasoning': true,
          'custom_api': {
            'apiurl': ' https://deepseek-proxy.invalid/v1/// ',
            'source': 'deepseek',
            'key': '',
            'top_k': 4,
          },
          'tools': [_tool],
          'tool_choice': 'required',
          'json_schema': {
            'name': 'schema',
            'value': {'type': 'object'},
          },
        }),
      );
      await generation.result;
      final wire = recorder.requests.single;
      expect(wire.url.toString(), 'https://deepseek-proxy.invalid/v1/chat/completions');
      expect(wire.body['thinking'], {'type': 'enabled'});
      expect(wire.body.containsKey('top_k'), isFalse);
      final sentTool = (wire.body['tools']! as List<Object?>).single! as Map<String, Object?>;
      final parameters = (sentTool['function']! as Map<String, Object?>)['parameters']! as Map<String, Object?>;
      expect(parameters.containsKey('required'), isFalse);
      expect((_tool['function']! as Map<String, Object?>)['parameters'], containsPair('required', <Object?>[]));
      expect(wire.body['response_format'], {'type': 'json_object'});
      expect((wire.body['messages']! as List<Object?>).last, {
        'role': 'user',
        'content': 'JSON schema for the response:\n{\n    "type": "object"\n}',
      });
    },
  );

  test(
    'Helper real SSE assembles tool fragments and signatures while reasoning events survive a false return flag',
    () async {
      final h = await generationFixture();
      final recorder = _Recorder();
      h.model = TavernModelClient(clientFactory: () => _RecordingPeer(recorder));
      await h.reopen();
      final host = ScriptHost();
      host.onDispatch = (request, cancellation) async {
        if (request.name == 'GENERATION_BEFORE_END') {
          (request.args.first! as Map<String, Object?>)['message'] = 'listener replacement';
        }
        return TavernScriptDispatchAck(eventId: request.eventId);
      };
      h.bridge.attachHost(host);
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'sse-helper'));
      recorder.responses.add(
        _sseResponse([
          {
            'choices': [
              {
                'delta': {
                  'role': 'assistant',
                  'reasoning_content': '思',
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_one',
                      'type': 'function',
                      'function': {'name': 'lo', 'arguments': '{"q":'},
                    },
                  ],
                  'reasoning_details': [
                    {'type': 'reasoning.encrypted', 'id': 'reasoning', 'data': 'reasoning-signature'},
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {
                  'reasoning_content': '考',
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'name': 'ok', 'arguments': '1}'},
                    },
                  ],
                  'reasoning_details': [
                    {'type': 'reasoning.encrypted', 'id': 'call_one', 'data': 'tool-signature'},
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
            ],
          },
        ]),
      );
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'generation_id': 'tool-stream',
          'should_stream': true,
          'should_return_reasoning': false,
          'ordered_prompts': [
            {'role': 'user', 'content': 'Q'},
          ],
          'custom_api': {'source': 'openrouter', 'apiurl': 'https://router.invalid/v1', 'key': 'synthetic'},
          'tools': [_tool],
        }),
      );
      final result = await generation.result;
      await Future<void>.delayed(Duration.zero);
      expect(result.reasoning, '思考');
      expect(result.toHelperValue(), {
        'content': '',
        'reasoning': '思考',
        'reasoning_signature': 'reasoning-signature',
        'tool_calls': [
          {
            'id': 'call_one',
            'type': 'function',
            'function': {'name': 'look', 'arguments': '{"q":1}'},
            'thought_signature': 'tool-signature',
          },
        ],
      });
      expect(recorder.requests.single.body['reasoning'], containsPair('exclude', false));
      expect(host.deliveries.where((event) => event.name == 'REASONING_TOKEN_RECEIVED_FULLY').last.args, [
        '思考',
        'tool-stream',
      ]);
      final names = host.deliveries.map((event) => event.name).toList();
      expect(names.indexOf('GENERATION_BEFORE_END'), lessThan(names.indexOf('GENERATION_ENDED')));
      expect(host.deliveries.singleWhere((event) => event.name == 'GENERATION_ENDED').args, ['', 'tool-stream', '思考']);
    },
  );

  test('Helper missing provider/image/proxy capabilities fail visibly before HTTP', () async {
    final h = await generationFixture();
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'missing-capability'));
    for (final option in <ScriptJson>[
      {
        'custom_api': {'source': 'claude', 'apiurl': 'https://unsupported.invalid'},
      },
      {
        'image': 'https://image.invalid/unresolved.png',
        'ordered_prompts': ['user_input'],
        'user_input': 'Q',
      },
      {
        'custom_api': {'proxy_preset': 'Unavailable'},
      },
    ]) {
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'ordered_prompts': [
            {'role': 'user', 'content': 'Q'},
          ],
          ...option,
        }),
      );
      expect((await generationFailure(generation)).code, TavernScriptErrorCode.unsupportedCapability);
    }
    expect(h.requests, isEmpty);
    expect((h.bridge as TavernHelperGenerationControl).helperGenerationState.activeIds, isEmpty);
  });

  test('Helper raw reserves plain text and charges the image only at the inner add boundary', () async {
    final h = await generationFixture();
    const counter = EstimatedTokenCounter();
    final imageMessage = <String, Object?>{
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'Q'},
        {
          'type': 'image_url',
          'image_url': {'url': _png, 'detail': 'low'},
        },
      ],
    };
    final plainCost = counter.countMessage({'role': 'user', 'content': 'Q'});
    final imageCost = counter.countMessage(imageMessage);
    expect(imageCost, greaterThan(plainCost));
    await h.engine.setPreset(
      ChatPreset({
        ...scriptPreset().raw,
        'openai_max_context': 3 + 1 + plainCost + imageCost,
        'openai_max_tokens': 1,
        'new_chat_prompt': '',
        'send_if_empty': '',
      }),
    );
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'image-budget'));
    final response = h.reply('image fits');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernHelperRawRequest.fromJson({
        'user_input': 'Q',
        'image': _png,
        'ordered_prompts': ['user_input'],
      }),
    );
    final wire = await generationRequest(generation, response);
    expect((await generation.result).text, 'image fits');
    expect(generationMessages(wire), [imageMessage]);
  });

  test('Helper raw absent input plus absent or filtered history leaves a single image unread', () async {
    final h = await generationFixture();
    await h.engine.setPreset(ChatPreset({...scriptPreset().raw, 'send_if_empty': ''}));
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'image-unread'));
    for (final filtered in [false, true]) {
      final response = h.reply('plain');
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'user_input': 'Q',
          'image': 'https://image.invalid/intentionally-unread.png',
          'ordered_prompts': filtered ? ['chat_history'] : <Object?>[],
          if (filtered)
            'overrides': {
              'chat_history': {'prompts': <Object?>[]},
            },
        }),
      );
      final wire = await generationRequest(generation, response);
      await generation.result;
      expect(generationMessages(wire), [
        {'role': 'user', 'content': 'Q'},
      ]);
    }
  });

  for (final afterDone in [false, true]) {
    test('Helper metadata uses production SSE dispatch boundaries (afterDone=$afterDone)', () async {
      final h = await generationFixture();
      final recorder = _Recorder();
      h.model = TavernModelClient(clientFactory: () => _RecordingPeer(recorder));
      await h.reopen();
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'frame-boundary'));
      String frame(ScriptJson delta, {String? reason}) =>
          'data: ${jsonEncode({
            'choices': [
              {'index': 0, 'delta': delta, 'finish_reason': ?reason},
            ],
          })}\n\n';
      final legal = frame({
        'tool_calls': [
          {
            'index': 0,
            'id': 'call_one',
            'type': 'function',
            'function': {'name': 'look', 'arguments': '{}'},
          },
        ],
      }, reason: 'tool_calls');
      final late = frame({
        'tool_calls': [
          {
            'index': 0,
            'function': {'name': 'LATE', 'arguments': 'TAIL'},
          },
        ],
      });
      final data = '$legal${afterDone ? 'data: [DONE]\n\n$late' : late.substring(0, late.length - 1)}';
      recorder.responses.add(
        http.StreamedResponse(Stream.value(utf8.encode(data)), 200, headers: {'content-type': 'text/event-stream'}),
      );
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'should_stream': true,
          'ordered_prompts': [
            {'role': 'user', 'content': 'Q'},
          ],
          'tools': [_tool],
        }),
      );
      final result = (await generation.result).toHelperValue() as ScriptJson;
      expect(result['tool_calls'], [
        {
          'id': 'call_one',
          'type': 'function',
          'function': {'name': 'look', 'arguments': '{}'},
        },
      ]);
    });
  }

  test(
    'Helper parsed frames merge recursive tool fields, clear nulls, and retain the last streaming signature',
    () async {
      final h = await generationFixture();
      final recorder = _Recorder();
      h.model = TavernModelClient(clientFactory: () => _RecordingPeer(recorder));
      await h.reopen();
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'merge-fields'));
      recorder.responses.add(
        _sseResponse([
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_',
                      'function': {
                        'name': 'lo',
                        'arguments': {'x': 1},
                      },
                    },
                    {
                      'index': 1,
                      'id': 'call_null',
                      'function': {'name': 'clear', 'arguments': '{'},
                    },
                    {
                      'index': 2,
                      'id': 'call_fresh',
                      'function': {
                        'name': 'old',
                        'arguments': {'old': true},
                      },
                    },
                  ],
                  'reasoning_details': [
                    {'type': 'reasoning.encrypted', 'id': 'reasoning', 'data': 'sig-first'},
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'one',
                      'function': {
                        'name': 'ok',
                        'arguments': {'y': 2},
                      },
                    },
                    {'index': 1, 'function': null},
                    {'index': 2, 'function': null},
                  ],
                  'reasoning_details': [
                    {'type': 'reasoning.encrypted', 'id': 'reasoning', 'data': 'sig-last'},
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 2,
                      'function': {'name': 'fresh', 'arguments': '{}'},
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          },
        ]),
      );
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'should_stream': true,
          'ordered_prompts': [
            {'role': 'user', 'content': 'Q'},
          ],
          'tools': [_tool],
          'custom_api': {'source': 'openrouter', 'apiurl': 'https://router.invalid/v1', 'key': 'synthetic'},
        }),
      );
      final result = (await generation.result).toHelperValue() as ScriptJson;
      expect(result['reasoning_signature'], 'sig-last');
      expect(result['tool_calls'], [
        {
          'id': 'call_one',
          'type': 'function',
          'function': {'name': 'look', 'arguments': '{"x":1,"y":2}'},
        },
        {
          'id': 'call_null',
          'type': 'function',
          'function': {'name': '', 'arguments': '{}'},
        },
        {
          'id': 'call_fresh',
          'type': 'function',
          'function': {'name': 'fresh', 'arguments': '{}'},
        },
      ]);
    },
  );

  test(
    'Helper nonstream OpenRouter keeps the first reasoning signature and the source tool signature precedence',
    () async {
      final h = await generationFixture();
      final recorder = _Recorder();
      h.model = TavernModelClient(clientFactory: () => _RecordingPeer(recorder));
      await h.reopen();
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'nonstream-signatures'));
      recorder.responses.add(
        _jsonResponse({
          'role': 'assistant',
          'content': '',
          'reasoning_details': [
            {'type': 'reasoning.encrypted', 'id': 'r1', 'data': 'first'},
            {'type': 'reasoning.encrypted', 'id': 'r2', 'data': 'last'},
            {'type': 'reasoning.encrypted', 'id': 'call_one', 'data': 'details'},
          ],
          'tool_calls': [
            {
              'id': 'call_one',
              'signature': 'generic',
              'function': {'name': 'look', 'arguments': '{}'},
            },
          ],
        }, reason: 'tool_calls'),
      );
      final generation = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'ordered_prompts': [
            {'role': 'user', 'content': 'Q'},
          ],
          'tools': [_tool],
          'custom_api': {'source': 'openrouter', 'apiurl': 'https://router.invalid/v1', 'key': 'synthetic'},
        }),
      );
      final result = (await generation.result).toHelperValue() as ScriptJson;
      expect(result['reasoning_signature'], 'first');
      expect((result['tool_calls']! as List<Object?>).single, {
        'id': 'call_one',
        'type': 'function',
        'function': {'name': 'look', 'arguments': '{}'},
        'thought_signature': 'details',
      });
    },
  );

  test(
    'Helper cancellation during image preparation rejects active duplicate IDs and ignores a late resolver result',
    () async {
      final h = await generationFixture();
      final host = _BlockingImageHost();
      h.bridge.attachHost(host);
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'cancel-image-helper'));
      final control = h.bridge as TavernHelperGenerationControl;
      final first = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'generation_id': 'reusable',
          'user_input': 'first',
          'image': 'https://image.invalid/slow.png',
          'ordered_prompts': ['user_input'],
        }),
      );
      await generationSignal(first, host.entered.future);
      await expectLater(
        h.bridge.generateRaw(
          context.id,
          TavernHelperRawRequest.fromJson({
            'generation_id': 'reusable',
            'ordered_prompts': [
              {'role': 'user', 'content': 'duplicate'},
            ],
          }),
        ),
        throwsA(isA<TavernScriptException>().having((error) => error.code, 'code', TavernScriptErrorCode.duplicateId)),
      );
      expect(host.deliveries.where((event) => event.name == 'GENERATION_STARTED'), isEmpty);
      expect(await control.stopHelperGenerationById('reusable'), isTrue);
      expect((await generationFailure(first)).code, TavernScriptErrorCode.cancelled);
      expect(host.token!.isCancelled, isTrue);
      final plan = h.stream();
      final replacement = await h.bridge.generateRaw(
        context.id,
        TavernHelperRawRequest.fromJson({
          'generation_id': 'reusable',
          'should_stream': true,
          'ordered_prompts': [
            {'role': 'user', 'content': 'replacement'},
          ],
        }),
      );
      await generationSignal(replacement, plan.listening.future);
      host.result.complete(_png);
      await Future<void>.delayed(Duration.zero);
      expect(control.helperGenerationState.activeIds, ['reusable']);
      expect(h.requests, hasLength(1), reason: 'The cancelled image request never reached HTTP.');
      expect(host.deliveries.where((event) => event.name == 'GENERATION_STARTED'), hasLength(1));
      plan.delta('replacement survived');
      plan.finish();
      expect((await replacement.result).text, 'replacement survived');
    },
  );
}

class _BlockingImageHost extends ScriptHost implements TavernHelperImageHost {
  final entered = Completer<void>();
  final result = Completer<String>();
  TavernScriptCancellation? token;
  @override
  Future<String> resolveHelperImage(String source, TavernScriptCancellation cancellation) {
    token = cancellation;
    entered.complete();
    return result.future;
  }
}

class _HelperHost extends ScriptHost implements TavernHelperProxyHost, TavernHelperImageHost {
  TavernHelperProxy? proxy;
  final proxies = <String>[];
  final images = <String>[];
  @override
  Future<TavernHelperProxy?> resolveHelperProxy(String name, TavernScriptCancellation cancellation) async {
    proxies.add(name);
    if (cancellation.isCancelled) throw StateError('Synthetic resolver cancelled.');
    return proxy;
  }

  @override
  Future<String> resolveHelperImage(String source, TavernScriptCancellation cancellation) async {
    images.add(source);
    if (cancellation.isCancelled) throw StateError('Synthetic resolver cancelled.');
    return _png;
  }
}

class _Wire {
  _Wire(this.url, this.headers, this.body);
  final Uri url;
  final Map<String, String> headers;
  final ScriptJson body;
}

class _Recorder {
  final requests = <_Wire>[];
  final responses = <http.StreamedResponse>[];
}

class _RecordingPeer extends http.BaseClient {
  _RecordingPeer(this.recorder);
  final _Recorder recorder;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    recorder.requests.add(
      _Wire(request.url, {
        for (final entry in request.headers.entries) entry.key.toLowerCase(): entry.value,
      }, jsonDecode(utf8.decode(bytes)) as ScriptJson),
    );
    return recorder.responses.isEmpty
        ? _jsonResponse({'role': 'assistant', 'content': 'ok'})
        : recorder.responses.removeAt(0);
  }
}

http.StreamedResponse _jsonResponse(ScriptJson message, {String reason = 'stop'}) => http.StreamedResponse(
  Stream.value(
    utf8.encode(
      jsonEncode({
        'choices': [
          {'message': message, 'finish_reason': reason},
        ],
      }),
    ),
  ),
  200,
  headers: {'content-type': 'application/json'},
);

http.StreamedResponse _sseResponse(List<ScriptJson> events) {
  final bytes = utf8.encode('${events.map((event) => 'data: ${jsonEncode(event)}\n\n').join()}data: [DONE]\n\n');
  return http.StreamedResponse(
    Stream.fromIterable([
      for (var i = 0; i < bytes.length; i += 7) bytes.sublist(i, i + 7 < bytes.length ? i + 7 : bytes.length),
    ]),
    200,
    headers: {'content-type': 'text/event-stream'},
  );
}
