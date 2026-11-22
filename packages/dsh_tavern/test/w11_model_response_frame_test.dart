import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  for (final streaming in [false, true]) {
    test('Optional text projection cannot mutate collector, usage or frame evidence (stream=$streaming)', () async {
      final peer = _Peer(streaming);
      final model = TavernModelClient(clientFactory: () => peer);
      final observed = <Map<String, Object?>>[];
      final bytes = <int>[];
      final context = ModelRequestContext(
        cancellation: ModelCancellation(),
        onUsageReport: (_) {},
        onResponseBytes: (_, chunk) => bytes.addAll(chunk),
        projectResponseText: (stream, frame) {
          expect(stream, streaming);
          final choice = (frame['choices']! as List<Object?>).single! as Map<String, Object?>;
          final message = choice[stream ? 'delta' : 'message']! as Map<String, Object?>;
          message['content'] = 'projection must not rewrite evidence';
          message['tool_calls'] = <Object?>[];
          (frame['usage']! as Map<String, Object?>)['prompt_tokens'] = 0;
          return (text: 'projected', reasoning: 'chosen');
        },
        onResponseFrame: (attempt, stream, frame) {
          expect(attempt, 0);
          expect(stream, streaming);
          observed.add(frame);
          return null;
        },
      );
      final deltas = await model.generate(config: _config, body: {'stream': streaming}, cancellation: context).toList();
      expect(deltas.whereType<ModelText>().map((delta) => delta.text), ['projected']);
      expect(deltas.whereType<ModelReasoning>().map((delta) => delta.text), ['chosen']);
      expect(deltas.whereType<ModelUsage>().single.usage.promptTokens, 7);
      expect(deltas.whereType<ModelToolFragment>().single.id, 'call_original');
      final snapshot = deltas.whereType<ModelFinished>().single.assistantSnapshot!;
      expect(snapshot.wireMessage['content'], 'wire');
      expect((snapshot.wireMessage['tool_calls']! as List<Object?>).single, {
        'id': 'call_original',
        'type': 'function',
        'function': {'name': 'look', 'arguments': '{}'},
      });
      expect(observed, hasLength(1), reason: 'SSE comments and DONE do not create response frames.');
      final observedChoice = (observed.single['choices']! as List<Object?>).single! as Map<String, Object?>;
      expect((observedChoice[streaming ? 'delta' : 'message']! as Map<String, Object?>)['content'], 'wire');
      expect((observed.single['usage']! as Map<String, Object?>)['prompt_tokens'], 7);
      expect(utf8.decode(bytes), contains('"content":"wire"'));
      expect(peer.sends, 1);
      expect(peer.closed, isTrue);
    });

    for (final asynchronous in [false, true]) {
      test('Owned response frame preserves the original failure (stream=$streaming, async=$asynchronous)', () async {
        final peer = _Peer(streaming);
        final failure = StateError('owned frame failure');
        final context = ModelRequestContext(
          cancellation: ModelCancellation(),
          onUsageReport: (_) {},
          onResponseFrame: (_, _, _) {
            if (asynchronous) return Future<void>.error(failure);
            throw failure;
          },
        );
        await expectLater(
          TavernModelClient(
            clientFactory: () => peer,
          ).generate(config: _config, body: {'stream': streaming}, cancellation: context).toList(),
          throwsA(same(failure)),
        );
        expect(peer.sends, 1);
        expect(peer.closed, isTrue);
      });
    }

    test('Owned projection failure is not reclassified or retried (stream=$streaming)', () async {
      final peer = _Peer(streaming);
      final failure = FormatException('projection type failure');
      final context = ModelRequestContext(
        cancellation: ModelCancellation(),
        onUsageReport: (_) {},
        projectResponseText: (_, _) => throw failure,
      );
      await expectLater(
        TavernModelClient(
          clientFactory: () => peer,
        ).generate(config: _config, body: {'stream': streaming}, cancellation: context).toList(),
        throwsA(same(failure)),
      );
      expect(peer.sends, 1);
      expect(peer.closed, isTrue);
    });
  }
}

final _config = TavernModelConfig(
  apiKey: () async => 'synthetic',
  baseUrl: 'https://frame.invalid/v1',
  deepseek: false,
);

class _Peer extends http.BaseClient {
  _Peer(this.streaming);
  final bool streaming;
  int sends = 0;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    await request.finalize().drain<void>();
    final message = <String, Object?>{
      'role': 'assistant',
      'content': 'wire',
      'reasoning_content': 'native-reasoning',
      'tool_calls': [
        {
          if (streaming) 'index': 0,
          'id': 'call_original',
          'type': 'function',
          'function': {'name': 'look', 'arguments': '{}'},
        },
      ],
    };
    final frame = {
      'choices': [
        {'index': 0, streaming ? 'delta' : 'message': message, 'finish_reason': 'stop'},
      ],
      'usage': {'prompt_tokens': 7, 'completion_tokens': 2},
    };
    final body = streaming ? ': heartbeat\n\ndata: ${jsonEncode(frame)}\n\ndata: [DONE]\n\n' : jsonEncode(frame);
    return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
  }

  @override
  void close() => closed = true;
}
