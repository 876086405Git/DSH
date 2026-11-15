import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/unknown_results.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the engine reported for a real interrupted bash call.
final _fixture = jsonDecode(
  File('../packages/dsh_client/test/fixtures/lifecycle-real-unknown.json').readAsStringSync(),
) as Map<String, dynamic>;
final _session = _fixture['sessionId'] as String;

Map<String, dynamic> _state(String key) => jsonDecode(jsonEncode(_fixture[key])) as Map<String, dynamic>;

void main() {
  late HttpServer server;
  late DshClient client;
  late Object Function(HttpRequest) answer;
  final requests = <String>[];

  setUp(() async {
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.method);
      await utf8.decodeStream(request);
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(answer(request)));
      await request.response.close();
    });
    client = DshClient(
      DshConnection(
        Uri.parse('http://127.0.0.1:${server.port}'),
        cookie: DshCookie(name: 'dsh-fixture', value: 'fixture', authority: '127.0.0.1:${server.port}'),
      ),
    );
  });

  tearDown(() async {
    await client.close();
    await server.close(force: true);
  });

  Future<UnknownResults> read() async => UnknownResults(client, await client.getLifecycleStatus(_session));

  test('reading the state never acknowledges anything', () async {
    answer = (_) => _state('unknown');
    final state = await read();
    expect(state.pending, isTrue);
    expect(state.toolNames, ['bash']);
    expect(requests, ['GET']);
  });

  test('goes on when the calls are still the ones the user saw', () async {
    answer = (request) => request.method == 'GET' ? _state('unknown') : _state('acknowledged');
    expect(await abandonUnknownResults(await read(), isCurrent: () => true), AbandonOutcome.done);
    expect(requests, ['GET', 'GET', 'POST']);
  });

  test('stops when another call has joined them', () async {
    answer = (_) => _state('unknown');
    final seen = await read();
    answer = (_) {
      final state = _state('unknown');
      final calls = state['calls'] as List<dynamic>;
      final added = jsonDecode(jsonEncode(calls.last)) as Map<String, dynamic>;
      added['callSeq'] = (added['callSeq'] as int) + 1000;
      calls.add(added);
      return state;
    };
    expect(await abandonUnknownResults(seen, isCurrent: () => true), AbandonOutcome.changed);
    expect(requests, isNot(contains('POST')));
  });

  test('stops when the engine has restarted since', () async {
    answer = (_) => _state('unknown');
    final seen = await read();
    answer = (_) => _state('unknown')..['bootId'] = 'another-boot';
    expect(await abandonUnknownResults(seen, isCurrent: () => true), AbandonOutcome.changed);
    expect(requests, isNot(contains('POST')));
  });

  test('is only read for a local engine that keeps the record', () async {
    answer = (_) => _state('unknown');
    final connection = HostConnection(client: client, label: 'test', isLocal: true);

    Future<UnknownResults?> withHost({required bool durable, required HostConnection connection}) async {
      final container = ProviderContainer(
        overrides: [
          durableCallsHostProvider.overrideWithValue(durable),
          activeConnectionProvider.overrideWithValue(AsyncValue.data(connection)),
        ],
      );
      addTearDown(container.dispose);
      return container.read(unknownResultsProvider(_session).future);
    }

    expect(await withHost(durable: false, connection: connection), isNull);
    expect(requests, isEmpty);
    final remote = HostConnection(client: client, label: 'test', isLocal: false);
    expect(await withHost(durable: true, connection: remote), isNull);
    expect(requests, isEmpty);
    expect((await withHost(durable: true, connection: connection))?.pending, isTrue);
  });
}
