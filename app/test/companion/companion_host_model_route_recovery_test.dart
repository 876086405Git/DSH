import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/companion_notes_peer.dart';

const _turn = {
  'kind': 'agent',
  'requestId': 'fixture-turn',
  'system': 'Test system.',
  'messages': [
    {'role': 'user', 'content': 'fixture'},
  ],
  'maxTokens': 20,
};

const _openTool = {
  'type': 'content_block_start',
  'index': 0,
  'content_block': {'type': 'tool_use', 'id': 'call-a', 'name': 'sample', 'input': {}},
};
const _stop = {'type': 'message_stop'};

Future<List<Map<String, Object?>>> _receive(List<Object> events) async {
  final route = HostModelRoute()
    ..model = () => MockClient.streaming((_, _) async {
      final lines = events.map((event) => 'data: ${jsonEncode(event)}\n\n').join();
      return http.StreamedResponse(Stream.value(utf8.encode(lines)), 200);
    });
  final bytes = route.answer('POST', _turn).body;
  return bytes.transform(utf8.decoder).transform(const LineSplitter())
      .map((line) => jsonDecode(line) as Map<String, Object?>)
      .toList()
      .timeout(const Duration(seconds: 5));
}

void main() {
  test('cancels the late body after the reader leaves before headers', () async {
    final requested = Completer<void>();
    final headers = Completer<http.StreamedResponse>();
    final retired = Completer<void>();
    final body = StreamController<List<int>>(onCancel: () => retired.complete());
    final route = HostModelRoute()
      ..model = () => MockClient.streaming((_, _) {
        requested.complete();
        return headers.future;
      });
    final received = <List<int>>[];
    final reader = route.answer('POST', _turn).body.listen(received.add);
    try {
      await requested.future.timeout(const Duration(seconds: 5));
      await reader.cancel();
      final before = received.length;
      headers.complete(http.StreamedResponse(body.stream, 200));
      await retired.future.timeout(const Duration(seconds: 5));
      expect(received, hasLength(before));
    } finally {
      if (!headers.isCompleted) headers.complete(http.StreamedResponse(body.stream, 200));
      await reader.cancel();
      unawaited(body.close());
    }
  });

  for (final (name, bad) in <(String, Object)>[
    ('non-object data', ['unexpected']),
    ('event without a string type', {'type': 7}),
    ('bad nested object', {'type': 'content_block_start', 'index': 0, 'content_block': []}),
    ('unclosed tool', _openTool),
  ]) {
    test('rejects $name and never returns a completed message', () async {
      final frames = await _receive([bad, _stop]);
      expect(frames.where((row) => row['type'] == 'message'), isEmpty);
      final finish = frames.singleWhere((row) => row['type'] == 'finish');
      expect(finish['terminal'], 'provider_error');
      expect(finish['complete'], false);
      expect(finish['error'], {'code': 'provider-invalid-stream'});
    });
  }

  test('keeps an extension event and a properly closed tool call compatible', () async {
    final frames = await _receive([
      {'type': 'future-extension'},
      _openTool,
      {'type': 'content_block_delta', 'index': 0,
        'delta': {'type': 'input_json_delta', 'partial_json': '{"n":1}'}},
      {'type': 'content_block_stop', 'index': 0},
      _stop,
    ]);
    final message = frames.singleWhere((row) => row['type'] == 'message')['message'] as Map;
    final tool = (message['content'] as List).single as Map;
    expect(tool['input'], {'n': 1});
    final finish = frames.singleWhere((row) => row['type'] == 'finish');
    expect(finish['terminal'], 'tool-calls');
    expect(finish['complete'], true);
  });
}
