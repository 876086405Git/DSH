import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';
import 'spreset_engine_test.dart' show SPresetHost, preset;

class _CapabilityHost extends SPresetHost implements TavernSPresetToolCapabilityHost {
  final lookups = <TavernSPresetToolCapabilityRequest>[];
  final tokens = <TavernScriptCancellation>[];
  FutureOr<TavernSPresetToolModelLookup> Function(TavernSPresetToolCapabilityRequest)? handlerLookup;
  TavernSPresetToolModelLookup value = const TavernSPresetToolModelLookup.noMatch();

  @override
  FutureOr<TavernSPresetToolModelLookup> lookupSPresetToolModel(
    TavernSPresetToolCapabilityRequest request,
    TavernScriptCancellation cancellation,
  ) {
    lookups.add(request);
    tokens.add(cancellation);
    return handlerLookup?.call(request) ?? value;
  }
}

typedef _Fixture = ({ScriptFixture h, String chat, TavernScriptContext context});
typedef _Active = ({TavernScriptGeneration generation, ScriptResponsePlan response});

TavernSPresetToolModelLookup _matched(Object? parameters) =>
    TavernSPresetToolModelLookup.matched({'id': 'catalog-model', 'supported_parameters': parameters});

Future<_Fixture> _fixture(
  SPresetHost host, {
  bool stream = true,
  bool calling = true,
  bool finalHook = false,
  TavernModelClient? client,
}) async {
  final h = await generationFixture();
  h.config = TavernModelConfig(
    apiKey: () async => 'synthetic-key',
    baseUrl: 'https://openrouter.ai/api/v1',
    model: 'catalog-model',
    deepseek: false,
    thinking: false,
  );
  if (client != null) h.model = client;
  await h.reopen();
  host.handler = (request) async {
    if (request.stage == 'ToolCallFormatter') {
      return TavernSPresetEvaluationResult(requestId: request.requestId, value: 'formatted');
    }
    if (request.stage == 'OutputPreprocessing') {
      return TavernSPresetEvaluationResult(
        requestId: request.requestId,
        value: scriptMap(request.arguments.single)['chunk'],
      );
    }
    return host.defaultEvaluate(request);
  };
  h.bridge.attachHost(host);
  final raw = preset(
    {
      if (finalHook) 'FinalRequestProcessing': {'enabled': true, 'script': 'fixture'},
      'OutputPreprocessing': {
        'enabled': true,
        'script': 'echo',
        'consumeToolCalls': true,
        'toolCallFormatter': {'enabled': true, 'script': 'fixture'},
      },
    },
    stream: stream,
    calling: calling,
  ).raw;
  // Saved connection settings must not select the capability source or model.
  raw['chat_completion_source'] = 'openai';
  raw['openai_model'] = 'gpt-6-astra';
  await h.engine.setPreset(ChatPreset(raw));
  final actor = await h.card('Capability actor');
  final chat = await h.emptyChat(actor);
  return (h: h, chat: chat, context: await h.context(chat, characterId: actor));
}

Map<String, Object?> _call(String id, int index) => {
  'index': index,
  'id': id,
  'type': 'function',
  'function': {'name': 'fixture_$id', 'arguments': '{"text":"$id"}'},
};

void _frame(ScriptResponsePlan response, {String id = 'call', int index = 0, List<Object?> details = const []}) {
  generationSse(response, {
    'choices': [
      {
        'index': 0,
        'delta': {
          if (index == 0) 'content': 'body',
          'tool_calls': [_call(id, index)],
          if (details.isNotEmpty) 'reasoning_details': details,
        },
      },
    ],
  }, splitAt: 7);
}

Future<_Active> _start(_Fixture fixture) async {
  final response = fixture.h.stream();
  final generation = await fixture.h.bridge.generate(
    fixture.context.id,
    TavernScriptGenerateRequest(userInput: 'question', stream: true),
  );
  await generationRequest(generation, response);
  await generationSignal(generation, response.listening.future);
  return (generation: generation, response: response);
}

List<TavernSPresetEvaluationRequest> _formats(SPresetHost host) =>
    host.evaluations.where((request) => request.stage == 'ToolCallFormatter').toList();

// Explicit old-client fixture: no HTTP decoder; its native fragment ABI remains
// available. With observe=true the callback is invoked without an async wrapper,
// so tests can detect any gratuitous Future added to a synchronous observation.
class _FragmentClient extends TavernModelClient {
  _FragmentClient({this.observe = false});
  final bool observe;
  final observerResults = <Future<void>?>[];
  final order = <String>[];
  int requests = 0;

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    requests++;
    late StreamController<ModelDelta> source;
    source = StreamController<ModelDelta>(
      onListen: () {
        void emit() {
          order.add('emit');
          source.add(const ModelText('body'));
          source.add(ModelToolFragment(index: 0, id: 'call', type: 'function', name: 'fixture', arguments: '{}'));
          source.add(const ModelFinished('tool_calls'));
          unawaited(source.close());
        }

        if (observe) {
          order.add('before');
          final context = cancellation as ModelRequestContext;
          final result = context.onResponseFrame!(0, true, {
            'choices': [
              {
                'index': 0,
                'delta': {
                  'tool_calls': [_call('call', 0)],
                },
              },
            ],
          });
          observerResults.add(result);
          order.add('after');
          if (result != null) {
            unawaited(
              result.then(
                (_) => emit(),
                onError: (Object error, StackTrace stack) {
                  source.addError(error, stack);
                  unawaited(source.close());
                },
              ),
            );
            return;
          }
        }
        emit();
      },
    );
    return source.stream;
  }
}

void main() {
  for (final (name, lookup, consumes) in [
    ('supported', _matched(['tools']), true),
    ('empty parameters', _matched([]), false),
    ('missing parameters', TavernSPresetToolModelLookup.matched({'id': 'catalog-model'}), false),
    ('no matching model', const TavernSPresetToolModelLookup.noMatch(), true),
    ('catalog not supplied', const TavernSPresetToolModelLookup.notSupplied(reason: 'id-only host'), true),
  ]) {
    test('HTTP streaming formatter uses OpenRouter catalog: $name', () async {
      final host = _CapabilityHost()..value = lookup;
      final fixture = await _fixture(host);
      final active = await _start(fixture);
      _frame(active.response);
      active.response.finish();
      if (consumes) {
        final result = await active.generation.result;
        expect(result.text, 'body\nformatted');
        expect(result.hookIssues.where((issue) => issue.stage == 'ToolCapability'), isEmpty);
        expect(_formats(host), hasLength(1));
      } else {
        expect((await generationFailure(active.generation)).code, TavernScriptErrorCode.unsupportedCapability);
        expect(_formats(host), isEmpty);
      }
      expect(host.lookups, hasLength(2), reason: 'One tool frame and one final empty frame.');
      expect(host.lookups.map((request) => request.chatId).toSet(), {fixture.chat});
      expect(host.lookups.map((request) => request.model).toSet(), {'catalog-model'});
      expect(host.lookups.map((request) => request.source).toSet(), {'openrouter'});
      expect(host.actions, 0);
      expect(fixture.h.requests, hasLength(1));
    });
  }

  test('valid async catalog results are adopted before formatting each HTTP frame', () async {
    final host = _CapabilityHost()..handlerLookup = (_) async => _matched(['tools']);
    final fixture = await _fixture(host);
    final active = await _start(fixture);
    _frame(active.response);
    active.response.finish();
    expect((await active.generation.result).text, 'body\nformatted');
    expect(host.lookups, hasLength(2));
    expect(_formats(host), hasLength(1));
  });

  test('disabled common setting avoids querying the optional catalog host', () async {
    final host = _CapabilityHost()..handlerLookup = (_) => throw StateError('Common gate precedes catalog lookup.');
    final fixture = await _fixture(host, calling: false);
    final active = await _start(fixture);
    _frame(active.response);
    active.response.finish();
    expect((await generationFailure(active.generation)).code, TavernScriptErrorCode.unsupportedCapability);
    expect(host.lookups, isEmpty);
    expect(_formats(host), isEmpty);
  });

  test('ordinary HTTP turn uses catalog formatting without granting native actions', () async {
    final host = _CapabilityHost()..value = _matched(['tools']);
    final fixture = await _fixture(host);
    final response = fixture.h.stream();
    final events = ScriptEvents(fixture.h.engine.send(fixture.chat, 'question'));
    await events.waitRequest(response);
    await response.listening.future;
    _frame(response);
    response.finish();
    await events.done.future;
    expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(events.values.whereType<TavernTurnDone>().single.message.text, 'body\nformatted');
    expect(host.actions, 0);
    expect(fixture.h.inspect((db) => db.select('SELECT COUNT(*) AS n FROM tool_receipts').single['n']), 0);
  });

  test('Mixed HTTP catalog retains native replay separately from blocked-frame signatures', () async {
    final host = _CapabilityHost();
    final values = [
      _matched(['tools']),
      _matched([]),
      const TavernSPresetToolModelLookup.noMatch(),
    ];
    host.handlerLookup = (_) => values.isEmpty ? const TavernSPresetToolModelLookup.noMatch() : values.removeAt(0);
    final fixture = await _fixture(host);
    final active = await _start(fixture);
    _frame(active.response, id: 'first');
    _frame(
      active.response,
      id: 'blocked',
      index: 1,
      details: [
        {'type': 'reasoning.encrypted', 'id': 'third', 'data': 'signature-from-blocked-frame'},
      ],
    );
    _frame(active.response, id: 'third', index: 2);
    active.response.finish();
    // A successful partial formatter must not swallow the unformatted native
    // call. Legacy background generation visibly rejects native tool replay.
    expect((await generationFailure(active.generation)).code, TavernScriptErrorCode.unsupportedCapability);
    expect(host.lookups, hasLength(4));
    final calls = (scriptMap(_formats(host).single.arguments.single)['calls']! as List).map(scriptMap).toList();
    expect(calls.map((call) => call['id']), ['first', 'third']);
    expect(calls.last['signature'], 'signature-from-blocked-frame');
    expect(host.actions, 0);
  });

  test('nonstream HTTP consumer does not query catalog even when support would be false', () async {
    final host = _CapabilityHost()..handlerLookup = (_) => throw StateError('Nonstream must not query capability.');
    final fixture = await _fixture(host, stream: false, calling: false);
    final response = generationJsonResponse(fixture.h, {
      'choices': [
        {
          'index': 0,
          'message': {
            'role': 'assistant',
            'content': 'body',
            'tool_calls': [_call('call', 0)],
          },
          'finish_reason': 'tool_calls',
        },
      ],
    });
    final generation = await fixture.h.bridge.generate(
      fixture.context.id,
      TavernScriptGenerateRequest(userInput: 'question', stream: false),
    );
    await generationRequest(generation, response);
    expect((await generation.result).text, 'body\nformatted');
    expect(host.lookups, isEmpty);
    expect(_formats(host), hasLength(1));
  });

  test('Mixed HTTP catalog replays all native calls through their existing authorization', () async {
    final host = _CapabilityHost();
    final values = [
      _matched(['tools']),
      _matched([]),
      _matched(['tools']),
    ];
    host.handlerLookup = (_) => values.isEmpty ? _matched(['tools']) : values.removeAt(0);
    final fixture = await _fixture(host);
    final response = fixture.h.stream();
    final events = ScriptEvents(fixture.h.engine.send(fixture.chat, 'question'));
    await events.waitRequest(response);
    await response.listening.future;
    _frame(response, id: 'first');
    _frame(response, id: 'blocked', index: 1);
    _frame(response, id: 'third', index: 2);
    response.finish();
    await events.done.future;
    expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
    final receipts = fixture.h.inspect(
      (db) => db.select('SELECT tool_name, status, result_json FROM tool_receipts ORDER BY tool_name'),
    );
    expect(receipts.map((row) => row['tool_name']), ['fixture_blocked', 'fixture_first', 'fixture_third']);
    expect(receipts.map((row) => row['status']), everyElement('rejected'));
    expect(receipts.map((row) => row['result_json']), everyElement(contains('unknown_tool')));
    expect(_formats(host), hasLength(1));
    expect(host.actions, 0, reason: 'Formatter eligibility does not grant native action permission.');
    expect(fixture.h.requests, hasLength(1));
  });

  for (final ordinary in [false, true]) {
    test('Malformed primary choice preserves consumption for ${ordinary ? 'ordinary' : 'background'} HTTP', () async {
      final host = _CapabilityHost();
      final values = [
        _matched(['tools']),
        _matched([]),
        _matched(['tools']),
      ];
      host.handlerLookup = (_) => values.removeAt(0);
      final fixture = await _fixture(host);
      final response = fixture.h.stream();
      ScriptEvents<TavernEvent>? events;
      TavernScriptGeneration? generation;
      if (ordinary) {
        events = ScriptEvents(fixture.h.engine.send(fixture.chat, 'question'));
        await events.waitRequest(response);
      } else {
        generation = await fixture.h.bridge.generate(
          fixture.context.id,
          TavernScriptGenerateRequest(userInput: 'question', stream: true),
        );
        await generationRequest(generation, response);
      }
      await response.listening.future;
      _frame(response, id: 'first');
      generationSse(response, {
        'choices': [
          null,
          {
            'index': 0,
            'delta': {
              'tool_calls': [_call('not-decoded', 1)],
            },
          },
        ],
      }, splitAt: 7);
      response.finish();
      if (events != null) {
        await events.done.future;
        expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
        expect(events.values.whereType<TavernTurnDone>().single.message.text, 'body\nformatted');
      } else {
        expect((await generation!.result).text, 'body\nformatted');
      }
      // The production decoder selects the leading non-map as an empty primary
      // choice. It never accepts not-decoded, so the unsupported frame must not
      // restore the already formatted first call to the native replay path.
      final calls = (scriptMap(_formats(host).single.arguments.single)['calls']! as List).map(scriptMap).toList();
      expect(calls.map((call) => call['id']), ['first']);
      expect(host.lookups, hasLength(3));
      expect(fixture.h.inspect((db) => db.select('SELECT COUNT(*) AS n FROM tool_receipts').single['n']), 0);
      expect(host.actions, 0);
      expect(fixture.h.requests, hasLength(1));
    });
  }

  test('captured source and model survive saved connection fields and Final wire rewrite', () async {
    final host = _CapabilityHost()..value = _matched(['tools']);
    final fixture = await _fixture(host, finalHook: true);
    final active = await _start(fixture);
    expect(fixture.h.requests.single.body['model'], 'final-model');
    _frame(active.response);
    active.response.finish();
    expect((await active.generation.result).text, 'body\nformatted');
    expect(host.lookups.map((request) => request.source).toSet(), {'openrouter'});
    expect(host.lookups.map((request) => request.model).toSet(), {'catalog-model'});
    expect(host.lookups.map((request) => request.generationId).toSet(), {active.generation.id});
  });

  test('capability requests identify each chat realm on the same dispatcher host', () async {
    final host = _CapabilityHost();
    final first = await _fixture(host);
    host.handlerLookup = (request) => request.chatId == first.chat ? _matched(['tools']) : _matched([]);
    final secondActor = await first.h.card('Second realm');
    final secondChat = await first.h.emptyChat(secondActor);
    final second = (
      h: first.h,
      chat: secondChat,
      context: await first.h.context(secondChat, characterId: secondActor, instanceId: 'second-realm'),
    );
    final a = await _start(first);
    _frame(a.response);
    a.response.finish();
    await a.generation.result;
    final b = await _start(second);
    _frame(b.response);
    b.response.finish();
    expect((await generationFailure(b.generation)).code, TavernScriptErrorCode.unsupportedCapability);
    expect(host.lookups.map((request) => request.chatId).toSet(), {first.chat, secondChat});
    expect(_formats(host).map((request) => request.generationId).toList(), [a.generation.id]);
  });

  for (final replace in [false, true]) {
    test('late async catalog is not adopted after ${replace ? 'host replacement' : 'cancel'}', () async {
      final entered = Completer<void>();
      final answer = Completer<TavernSPresetToolModelLookup>();
      final host = _CapabilityHost()
        ..handlerLookup = (_) {
          if (!entered.isCompleted) entered.complete();
          return answer.future;
        };
      final fixture = await _fixture(host);
      addTearDown(() {
        if (!answer.isCompleted) answer.complete(const TavernSPresetToolModelLookup.noMatch());
      });
      final active = await _start(fixture);
      _frame(active.response);
      await generationSignal(active.generation, entered.future);
      final replacement = SPresetHost();
      if (replace) {
        fixture.h.bridge.attachHost(replacement);
      } else {
        expect(fixture.h.bridge.stopGenerationById(active.generation.id), isTrue);
        expect((await generationFailure(active.generation)).code, TavernScriptErrorCode.cancelled);
      }
      expect(host.tokens.single.isCancelled, isTrue);
      expect(_formats(host), isEmpty);
      expect(host.released, isEmpty, reason: 'The existing operation drain still owns the pending host Future.');
      answer.complete(_matched(['tools']));
      active.response.finish();
      final failure = await generationFailure(active.generation);
      if (replace) expect(failure.issues.any((issue) => issue.stage == 'ToolCapability'), isTrue);
      expect(_formats(host), isEmpty);
      expect(replacement.evaluations, isEmpty);
      expect(fixture.h.requests, hasLength(1));
      await fixture.h.close();
      expect(host.released, isNotEmpty);
    });
  }

  for (final asyncError in [false, true]) {
    test('catalog ${asyncError ? 'async' : 'sync'} error is visible and is not noMatch fallback', () async {
      final host = _CapabilityHost()
        ..handlerLookup = (_) {
          if (asyncError) return Future<TavernSPresetToolModelLookup>.error(StateError('catalog fixture error'));
          throw StateError('catalog fixture error');
        };
      final fixture = await _fixture(host);
      final active = await _start(fixture);
      _frame(active.response);
      active.response.finish();
      final failure = await generationFailure(active.generation);
      expect(failure.issues.any((issue) => issue.stage == 'ToolCapability'), isTrue);
      expect(_formats(host), isEmpty);
      expect(fixture.h.requests, hasLength(1), reason: 'A consumer failure must not retry an accepted HTTP response.');
    });
  }

  for (final hasCapability in [false, true]) {
    test(
      'parsed-frame callback remains synchronous with ${hasCapability ? 'synchronous lookup' : 'no capability host'}',
      () async {
        final client = _FragmentClient(observe: true);
        final host = hasCapability ? (_CapabilityHost()..value = _matched(['tools'])) : SPresetHost();
        final fixture = await _fixture(host, client: client);
        final generation = await fixture.h.bridge.generate(
          fixture.context.id,
          TavernScriptGenerateRequest(userInput: 'question', stream: true),
        );
        expect((await generation.result).text, 'body\nformatted');
        expect(client.observerResults, [null]);
        expect(client.order, ['before', 'after', 'emit']);
        expect(client.requests, 1);
      },
    );
  }

  for (final supports in [false, true]) {
    test('legacy custom client consults stream catalog once at EOF, supports=$supports', () async {
      final client = _FragmentClient();
      final host = _CapabilityHost()..value = _matched(supports ? ['tools'] : []);
      final fixture = await _fixture(host, client: client);
      final generation = await fixture.h.bridge.generate(
        fixture.context.id,
        TavernScriptGenerateRequest(userInput: 'question', stream: true),
      );
      if (supports) {
        expect((await generation.result).text, 'body\nformatted');
      } else {
        expect((await generationFailure(generation)).code, TavernScriptErrorCode.unsupportedCapability);
        expect(_formats(host), isEmpty);
      }
      expect(host.lookups, hasLength(1));
      expect(client.observerResults, isEmpty);
      expect(host.actions, 0);
    });
  }

  test('legacy custom client nonstream formatting does not acquire a stream capability gate', () async {
    final client = _FragmentClient();
    final host = _CapabilityHost()..handlerLookup = (_) => throw StateError('Nonstream must not query capability.');
    final fixture = await _fixture(host, stream: false, calling: false, client: client);
    final generation = await fixture.h.bridge.generate(
      fixture.context.id,
      TavernScriptGenerateRequest(userInput: 'question', stream: false),
    );
    expect((await generation.result).text, 'body\nformatted');
    expect(host.lookups, isEmpty);
    expect(_formats(host), hasLength(1));
  });
}
