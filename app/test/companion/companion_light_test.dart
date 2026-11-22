import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_light.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _sse(List<Map<String, Object?>> events) =>
    [for (final event in events) 'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n'].join();

Map<String, Object?> _text(String text) => {
  'type': 'content_block_delta',
  'index': 0,
  'delta': {'type': 'text_delta', 'text': text},
};

MockClient _answering(int status, String body, {void Function(http.BaseRequest, String)? seen}) =>
    MockClient.streaming((request, bodyStream) async {
      seen?.call(request, await bodyStream.bytesToString());
      return http.StreamedResponse(Stream.value(utf8.encode(body)), status);
    });

Future<({String words, CompanionLightError? error, List<CompanionUsage> usage, int sent})> _heard(
  MockClient client, {
  String apiKey = 'sk-test',
}) async {
  addTearDown(client.close);
  final words = StringBuffer();
  final usage = <CompanionUsage>[];
  var sent = 0;
  CompanionLightError? error;
  try {
    await for (final word in streamCompanionReply(
      client: client,
      apiKey: apiKey,
      system: 'private instruction',
      lines: const [CompanionLine.user('private conversation')],
      onSent: () => sent++,
      onUsage: usage.add,
    )) {
      words.write(word);
    }
  } on CompanionLightError catch (failure) {
    error = failure;
  }
  return (words: words.toString(), error: error, usage: usage, sent: sent);
}

void main() {
  group('reply', () {
    test('keeps the start-frame output out of final counts and settles a dropped stream once', () async {
      for (final stopped in [true, false]) {
        final settlements = <(Map<String, Object?>, bool)>[];
        final result = streamCompanionReply(
          client: _answering(
            200,
            _sse([
              {
                'type': 'message_start',
                'message': {
                  'usage': {'input_tokens': 12, 'output_tokens': 0},
                },
              },
              _text('reply'),
              if (stopped) {'type': 'message_stop'},
            ]),
          ),
          apiKey: 'synthetic',
          system: 'synthetic',
          lines: const [CompanionLine.user('synthetic')],
          onUsageSettled: (usage, {required partial}) => settlements.add((usage, partial)),
        ).toList();
        if (stopped) {
          expect(await result, ['reply']);
        } else {
          await expectLater(result, throwsA(isA<CompanionLightError>()));
        }
        expect(settlements, hasLength(1));
        expect(settlements.single.$1, {'inputTokens': 12});
        expect(settlements.single.$2, !stopped);
      }
    });
    test('asks DeepSeek the way the engine does and streams her words', () async {
      late http.BaseRequest request;
      late Map<String, Object?> body;
      final client = _answering(
        200,
        _sse([
          {'type': 'message_start', 'message': <String, Object?>{}},
          {'type': 'ping'},
          _text('[表情:开心]'),
          _text('你来啦。'),
          {'type': 'message_delta', 'delta': <String, Object?>{}},
          {'type': 'message_stop'},
        ]),
        seen: (r, b) {
          request = r;
          body = jsonDecode(b) as Map<String, Object?>;
        },
      );
      final words = await streamCompanionReply(
        client: client,
        apiKey: 'sk-test',
        system: '你是鲸鱼娘',
        lines: const [CompanionLine.user('你好')],
      ).toList();
      expect(words.join(), '[表情:开心]你来啦。');
      expect(request.url.toString(), 'https://api.deepseek.com/anthropic/v1/messages');
      expect(request.headers['x-api-key'], 'sk-test');
      expect(request.headers['anthropic-version'], '2023-06-01');
      expect(body['model'], 'deepseek-flash');
      expect(body['stream'], isTrue);
      expect(body['thinking'], {'type': 'disabled'});
      expect(body['system'], '你是鲸鱼娘');
      expect(body['messages'], [
        {'role': 'user', 'content': '你好'},
      ]);
    });

    test('the final cumulative receipt keeps both raw objects, without adding or taking maxima', () async {
      const start = {'input_tokens': 900, 'cache_read_input_tokens': 300, 'output_tokens': 1};
      const finalUsage = {
        'input_tokens': 800,
        'cache_read_input_tokens': 200,
        'cache_creation_input_tokens': 0,
        'output_tokens': 42,
        'service_tier': 'standard',
        'server_tool_use': {'web_search_requests': 1},
      };
      final result = await _heard(
        _answering(
          200,
          _sse([
            {
              'type': 'message_start',
              'message': {'usage': start},
            },
            _text('你来啦。'),
            {
              'type': 'message_delta',
              'usage': {'output_tokens': 50},
            },
            {
              'type': 'message_delta',
              'delta': {'stop_reason': 'end_turn'},
              'usage': finalUsage,
            },
            {'type': 'message_stop'},
          ]),
        ),
      );
      expect(result.error, isNull);
      expect(result.words, '你来啦。');
      expect(result.sent, 1);
      final usage = result.usage.single;
      expect(usage.provider, 'deepseek');
      expect(usage.model, companionLightModel);
      expect(usage.startUsage, start);
      expect(usage.finalUsage, finalUsage);
      expect(usage.startEvent, 'message_start');
      expect(usage.finalEvent, 'message_delta');
      expect(usage.semantics, 'cumulative');
      expect(usage.inputUncached, 800);
      expect(usage.inputCacheRead, 200);
      expect(usage.inputCacheWrite, 0);
      expect(usage.outputTokens, 42);
      expect(usage.reportedInputTokens, 1000);
      expect(usage.stopReason, 'end_turn');
      expect(usage.terminal, 'complete');
      expect(usage.complete, isTrue);
      expect(usage.httpStatus, 200);
      expect(jsonDecode(jsonEncode(usage.toJson())), {
        'provider': 'deepseek',
        'model': companionLightModel,
        'start_usage': start,
        'final_usage': finalUsage,
        'start_event': 'message_start',
        'final_event': 'message_delta',
        'usage_semantics': 'cumulative',
        'input_uncached': 800,
        'input_cache_read': 200,
        'input_cache_write': 0,
        'output_tokens': 42,
        'stop_reason': 'end_turn',
        'terminal': 'complete',
        'complete': true,
        'http_status': 200,
      });
      final encoded = jsonEncode(usage.toJson());
      for (final privateText in ['private instruction', 'private conversation', '你来啦。', 'sk-test']) {
        expect(encoded, isNot(contains(privateText)));
      }
    });

    test('missing final components stay unknown and raw invalid values are preserved', () async {
      const raw = {
        'input_tokens': -1,
        'cache_read_input_tokens': '20',
        'cache_creation_input_tokens': 2.5,
        'output_tokens': 0,
      };
      final result = await _heard(
        _answering(
          200,
          _sse([
            {
              'type': 'message_start',
              'message': {
                'usage': {'input_tokens': 900, 'cache_read_input_tokens': 300},
              },
            },
            {
              'type': 'message_delta',
              'usage': {'input_tokens': 1000, 'output_tokens': 50},
            },
            {'type': 'message_delta', 'usage': raw},
            {'type': 'message_stop'},
          ]),
        ),
      );
      final usage = result.usage.single;
      expect(usage.finalUsage, raw);
      expect(usage.inputUncached, isNull);
      expect(usage.inputCacheRead, isNull);
      expect(usage.inputCacheWrite, isNull);
      expect(usage.outputTokens, 0);
      expect(usage.reportedInputTokens, isNull);

      final partial = await _heard(
        _answering(
          200,
          _sse([
            {
              'type': 'message_delta',
              'usage': {'cache_read_input_tokens': 12},
            },
            {'type': 'message_stop'},
          ]),
        ),
      );
      expect(partial.usage.single.inputUncached, isNull);
      expect(partial.usage.single.outputTokens, isNull);
      expect(partial.usage.single.reportedInputTokens, 12);
      expect(partial.usage.single.toJson()['output_tokens'], isNull);
    });

    test('a finished request without usage still has one receipt with unknown components', () async {
      final result = await _heard(
        _answering(
          200,
          _sse([
            {'type': 'message_start', 'message': <String, Object?>{}},
            _text('你来啦。'),
            {'type': 'message_stop'},
          ]),
        ),
      );
      final usage = result.usage.single;
      expect(usage.complete, isTrue);
      expect(usage.startUsage, isNull);
      expect(usage.finalUsage, isNull);
      expect(usage.startEvent, isNull);
      expect(usage.finalEvent, isNull);
      expect(usage.inputUncached, isNull);
      expect(usage.inputCacheRead, isNull);
      expect(usage.inputCacheWrite, isNull);
      expect(usage.outputTokens, isNull);
    });

    test('max_tokens and refusal are distinct terminal states even with message_stop', () async {
      for (final reason in ['max_tokens', 'refusal']) {
        final result = await _heard(
          _answering(
            200,
            _sse([
              _text('still delivered'),
              {
                'type': 'message_delta',
                'delta': {'stop_reason': reason},
                'usage': {'output_tokens': 8},
              },
              {'type': 'message_stop'},
            ]),
          ),
        );
        expect(result.error, isNull);
        expect(result.words, 'still delivered');
        expect(result.usage.single.stopReason, reason);
        expect(result.usage.single.terminal, reason);
        expect(result.usage.single.complete, isTrue);
        expect(result.usage.single.outputTokens, 8);
      }
    });

    test('onSent occurs at client.send, while no-key and failed local reservation never send', () async {
      final order = <String>[];
      final client = _answering(
        200,
        _sse([
          {'type': 'message_stop'},
        ]),
        seen: (_, _) => order.add('send'),
      );
      addTearDown(client.close);
      final stream = streamCompanionReply(
        client: client,
        apiKey: 'k',
        system: 's',
        lines: const [CompanionLine.user('hi')],
        onSent: () => order.add('sent'),
        onUsage: (_) => order.add('usage'),
      );
      expect(order, isEmpty);
      await stream.drain<void>();
      expect(order, ['sent', 'send', 'usage']);

      final noKey = await _heard(_answering(200, '', seen: (_, _) => fail('no key must not send')), apiKey: '  ');
      expect(noKey.error?.failure, CompanionLightFailure.noKey);
      expect(noKey.sent, 0);
      expect(noKey.usage, isEmpty);
      final localFailure = StateError('reservation failed');
      await expectLater(
        streamCompanionReply(
          client: _answering(200, '', seen: (_, _) => fail('failed reservation must not send')),
          apiKey: 'k',
          system: 's',
          lines: const [CompanionLine.user('hi')],
          onSent: () => throw localFailure,
          onUsage: (_) => fail('not sent, so no receipt callback'),
        ).drain<void>(),
        throwsA(same(localFailure)),
      );
    });

    test('HTTP and send failures each preserve one unknown receipt for the actual request', () async {
      for (final status in [401, 429, 500]) {
        final result = await _heard(_answering(status, 'error'));
        expect(result.error, isNotNull);
        expect(result.sent, 1);
        expect(result.usage.single.httpStatus, status);
        expect(result.usage.single.terminal, 'http_error');
        expect(result.usage.single.complete, isFalse);
        expect(result.usage.single.inputUncached, isNull);
        expect(result.usage.single.outputTokens, isNull);
      }
      final failed = await _heard(MockClient.streaming((_, _) async => throw const SocketException('offline')));
      expect(failed.error?.failure, CompanionLightFailure.network);
      expect(failed.sent, 1);
      expect(failed.usage.single.terminal, 'network_error');
      expect(failed.usage.single.httpStatus, isNull);
      expect(failed.usage.single.outputTokens, isNull);
    });

    test('a refused key, a busy model and an error event say which', () async {
      Future<CompanionLightFailure> failure(MockClient client) async {
        try {
          await streamCompanionReply(
            client: client,
            apiKey: 'k',
            system: 's',
            lines: const [CompanionLine.user('hi')],
          ).toList();
        } on CompanionLightError catch (error) {
          return error.failure;
        }
        fail('no error');
      }

      expect(await failure(_answering(401, '{"error":"bad key"}')), CompanionLightFailure.badKey);
      expect(await failure(_answering(429, '')), CompanionLightFailure.busy);
      expect(await failure(_answering(500, 'oops')), CompanionLightFailure.server);
      expect(
        await failure(
          _answering(
            200,
            _sse([
              _text('嗯'),
              {
                'type': 'error',
                'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
              },
            ]),
          ),
        ),
        CompanionLightFailure.busy,
      );
      expect(
        await failure(MockClient.streaming((_, _) async => throw const SocketException('offline'))),
        CompanionLightFailure.network,
      );
    });
  });

  group('reply ends', () {
    Future<(String, CompanionLightFailure?)> run(MockClient client) async {
      final words = StringBuffer();
      try {
        await for (final word in streamCompanionReply(
          client: client,
          apiKey: 'k',
          system: 's',
          lines: const [CompanionLine.user('hi')],
        )) {
          words.write(word);
        }
        return (words.toString(), null);
      } on CompanionLightError catch (error) {
        return (words.toString(), error.failure);
      }
    }

    test('a connection that closes before message_stop is a failure, after what it said', () async {
      final (words, failure) = await run(_answering(200, _sse([_text('说到一半')])));
      expect(words, '说到一半');
      expect(failure, CompanionLightFailure.network);
    });

    test('a lost message_stop keeps final usage; start-only disconnect keeps the final unknown', () async {
      const start = {'input_tokens': 100, 'cache_read_input_tokens': 25, 'output_tokens': 1};
      const finalUsage = {'input_tokens': 100, 'cache_read_input_tokens': 25, 'output_tokens': 37};
      for (final finalArrived in [false, true]) {
        final result = await _heard(
          _answering(
            200,
            _sse([
              {
                'type': 'message_start',
                'message': {'usage': start},
              },
              _text('说到一半'),
              if (finalArrived)
                {
                  'type': 'message_delta',
                  'delta': {'stop_reason': 'end_turn'},
                  'usage': finalUsage,
                },
            ]),
          ),
        );
        expect(result.words, '说到一半');
        expect(result.error?.failure, CompanionLightFailure.network);
        final usage = result.usage.single;
        expect(usage.complete, isFalse);
        expect(usage.terminal, 'incomplete');
        expect(usage.startUsage, start);
        expect(usage.finalUsage, finalArrived ? finalUsage : null);
        expect(usage.inputUncached, finalArrived ? 100 : null);
        expect(usage.inputCacheRead, finalArrived ? 25 : null);
        expect(usage.inputCacheWrite, isNull);
        expect(usage.outputTokens, finalArrived ? 37 : null);
      }
    });

    test('a provider error retains the reported usage and the original stream failure', () async {
      final result = await _heard(
        _answering(
          200,
          _sse([
            _text('嗯'),
            {
              'type': 'message_delta',
              'usage': {'input_tokens': 5, 'output_tokens': 2},
            },
            {
              'type': 'error',
              'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
            },
          ]),
        ),
      );
      expect(result.words, '嗯');
      expect(result.error?.failure, CompanionLightFailure.busy);
      expect(result.usage.single.terminal, 'provider_error');
      expect(result.usage.single.complete, isFalse);
      expect(result.usage.single.inputUncached, 5);
      expect(result.usage.single.outputTokens, 2);
    });

    test('cancelling after a text delta still emits exactly one unfinished receipt', () async {
      final body = StreamController<List<int>>();
      final client = MockClient.streaming((_, _) async => http.StreamedResponse(body.stream, 200));
      addTearDown(client.close);
      addTearDown(body.close);
      final usage = <CompanionUsage>[];
      final cancelled = Completer<void>();
      late StreamSubscription<String> sub;
      sub = streamCompanionReply(
        client: client,
        apiKey: 'k',
        system: 's',
        lines: const [CompanionLine.user('hi')],
        onUsage: usage.add,
      ).listen((_) => unawaited(sub.cancel().then((_) => cancelled.complete())));
      body.add(
        utf8.encode(
          _sse([
            {
              'type': 'message_start',
              'message': {
                'usage': {'input_tokens': 100, 'output_tokens': 1},
              },
            },
            _text('等等'),
          ]),
        ),
      );
      await cancelled.future;
      expect(usage, hasLength(1));
      expect(usage.single.terminal, 'cancelled');
      expect(usage.single.complete, isFalse);
      expect(usage.single.startUsage, {'input_tokens': 100, 'output_tokens': 1});
      expect(usage.single.finalUsage, isNull);
      expect(usage.single.outputTokens, isNull);
    });

    test('a bare error object with no type is a failure, not an empty success', () async {
      final (words, failure) = await run(_answering(200, 'data: {"error":{"message":"timeout"}}\n\n'));
      expect(words, isEmpty);
      expect(failure, CompanionLightFailure.server);
    });

    test('a refused key is reported even when its body never finishes', () async {
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final client = MockClient.streaming((_, _) async {
        body.add(utf8.encode('{"error":'));
        return http.StreamedResponse(body.stream, 401);
      });
      final watch = Stopwatch()..start();
      final (_, failure) = await run(client);
      expect(failure, CompanionLightFailure.badKey);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('history', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('companion-light'));
    tearDown(() => root.deleteSync(recursive: true));

    test('what the model gets starts with the person and alternates', () {
      final history = CompanionLightHistory.at(root)
        ..add(const CompanionLine.her('上一次的话'))
        ..add(const CompanionLine.user('在吗'))
        ..add(const CompanionLine.user('〔她刚才被摸了头〕\n嘿'))
        ..add(const CompanionLine.her('在呀'));
      expect(history.context().map((l) => (l.role, l.text)), [('user', '在吗\n〔她刚才被摸了头〕\n嘿'), ('assistant', '在呀')]);
    });

    test('only the latest lines go out, and only so many are kept', () {
      final history = CompanionLightHistory.at(root);
      for (var i = 0; i < 100; i++) {
        history
          ..add(CompanionLine.user('问$i'))
          ..add(CompanionLine.her('答$i'));
      }
      expect(history.lines, hasLength(CompanionLightHistory.keep));
      final sent = history.context();
      expect(sent, hasLength(CompanionLightHistory.window));
      expect(sent.first.fromHer, isFalse);
      expect(sent.last.text, '答99');
    });

    test('kept on disk; an unanswered line can be taken back; clear forgets', () async {
      final history = CompanionLightHistory.at(root)
        ..add(const CompanionLine.user('你好'))
        ..add(const CompanionLine.her('你好呀'))
        ..add(const CompanionLine.user('没回的话'));
      expect(history.dropUnanswered()?.text, '没回的话');
      expect(history.dropUnanswered(), isNull);
      await history.save();

      final again = CompanionLightHistory.at(root);
      await again.load();
      expect(again.lines.map((l) => l.text), ['你好', '你好呀']);

      await again.clear();
      final empty = CompanionLightHistory.at(root);
      await empty.load();
      expect(empty.lines, isEmpty);
    });

    test('every load waits for the one read: the old conversation stays first', () async {
      final old = CompanionLightHistory.at(root)
        ..add(const CompanionLine.user('上次'))
        ..add(const CompanionLine.her('上次的回答'));
      await old.save();
      final history = CompanionLightHistory.at(root);
      final first = history.load();
      await history.load();
      history.add(const CompanionLine.user('这次'));
      await first;
      expect(history.lines.map((l) => l.text), ['上次', '上次的回答', '这次']);
    });

    test('a closing page finishes its save before the next page reads', () async {
      final a = CompanionLightHistory.at(root)
        ..add(const CompanionLine.user('你好'))
        ..add(const CompanionLine.her('你好呀'));
      unawaited(a.save());
      final b = CompanionLightHistory.at(root);
      await b.load();
      expect(b.lines.map((l) => l.text), ['你好', '你好呀']);
    });

    test('a clear deletes only what came before it, and stops an earlier read', () async {
      final seed = CompanionLightHistory.at(root)..add(const CompanionLine.user('旧的'));
      await seed.save();
      final history = CompanionLightHistory.at(root);
      final reading = history.load();
      final clearing = history.clear();
      history.add(const CompanionLine.user('新的'));
      final saving = history.save();
      await reading;
      await clearing;
      await saving;
      expect(history.lines.map((l) => l.text), ['新的']);
      final again = CompanionLightHistory.at(root);
      await again.load();
      expect(again.lines.map((l) => l.text), ['新的']);
    });

    test('an unreadable file starts afresh', () async {
      File('${root.path}/light-chat.json').writeAsStringSync('{not json');
      final history = CompanionLightHistory.at(root);
      await history.load();
      expect(history.lines, isEmpty);
    });
  });
}
