// Explicit Flutter runner; this file is outside test/ discovery and config.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../tooling/companion/offline_http.dart';
import '../test/flutter_test_config.dart' as config;
import '../test/support/bundle_widgets.dart';
import '../test/companion/companion_host_memory_transport_test.dart' as host_transport;
import '../test/companion/companion_host_usage_owner_test.dart' as host_usage;
import '../test/companion/companion_initiative_owner_test.dart' as initiative_owner;
import '../test/companion/companion_initiative_test.dart' as initiative;
import '../test/companion/companion_invite_test.dart' as invite;
import '../test/companion/companion_light_test.dart' as light;
import '../test/companion/companion_memory_input_test.dart' as input;
import '../test/companion/companion_memory_control_replay_test.dart' as control_replay;
import '../test/companion/companion_memory_dates_replay_test.dart' as dates_replay;
import '../test/companion/companion_memory_idle_replay_test.dart' as idle_replay;
import '../test/companion/companion_memory_lifecycle_test.dart' as lifecycle;
import '../test/companion/companion_memory_owner_test.dart' as owner;
import '../test/companion/companion_memory_worker_test.dart' as worker;
import '../test/companion/companion_page_test.dart' as page;
import '../test/companion/companion_recall_room_test.dart' as recall_room;
import '../test/companion/companion_signal_initiative_test.dart' as signal_initiative;
import '../test/companion/companion_signal_owner_test.dart' as signal_owner;
import '../test/companion/companion_stream_state_test.dart' as stream_state;
import '../test/companion/companion_widget_memory_test.dart' as widget_memory;

final _offline = CompanionOfflineHttpOverrides();
final _blocked = throwsA(
  isA<SocketException>().having((error) => error.message, 'message', startsWith('offline companion replay')),
);

Future<void> main() => config.testExecutable(() {
  HttpOverrides.global = _offline;
  setUp(() => HttpOverrides.global = _offline);
  for (final suite in <String, void Function()>{
    'offline': _offlineTests,
    'test/companion/companion_memory_worker_test.dart': worker.main,
    'test/companion/companion_memory_input_test.dart': input.main,
    'test/companion/companion_memory_control_replay_test.dart': control_replay.main,
    'test/companion/companion_memory_dates_replay_test.dart': dates_replay.main,
    'test/companion/companion_memory_idle_replay_test.dart': idle_replay.main,
    'test/companion/companion_memory_lifecycle_test.dart': lifecycle.main,
    'test/companion/companion_memory_owner_test.dart': owner.main,
    'test/companion/companion_light_test.dart': light.main,
    'test/companion/companion_page_test.dart': page.main,
    'test/companion/companion_invite_test.dart': invite.main,
    'test/companion/companion_signal_owner_test.dart': signal_owner.main,
    'test/companion/companion_initiative_owner_test.dart': initiative_owner.main,
    'test/companion/companion_signal_initiative_test.dart': signal_initiative.main,
    'test/companion/companion_recall_room_test.dart': recall_room.main,
    'test/companion/companion_widget_memory_test.dart': widget_memory.main,
    'test/companion/companion_host_usage_owner_test.dart': host_usage.main,
    'test/companion/companion_host_memory_transport_test.dart': host_transport.main,
    'test/companion/companion_initiative_test.dart': initiative.main,
    'test/companion/companion_stream_state_test.dart': stream_state.main,
  }.entries) {
    bundledWidgets(suite.key, () {
      // bundledWidgets._freshBinding resets HttpOverrides.global. Register
      // this after its setUpAll and before the imported suite's own setup.
      setUpAll(() => HttpOverrides.global = _offline);
      suite.value();
    });
  }
  // Registering the first testWidgets initializes a binding and its HTTP mock.
  HttpOverrides.global = _offline;
});

void _offlineTests() {
  test('rejects external HTTP before DNS', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    for (final host in ['external.invalid', 'localhost', '192.0.2.1']) {
      await expectLater(client.getUrl(Uri.parse('http://$host/')), _blocked);
    }
    client.findProxy = (_) => 'PROXY 127.0.0.1:9';
    await expectLater(client.getUrl(Uri.parse('http://external.invalid/')), _blocked);
    await expectLater(client.getUrl(Uri.parse('http://127.0.0.1:9/')), _blocked);
  });
  test('allows numeric loopback HTTP', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write('offline-loopback');
      await request.response.close();
    });
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/'))).close();
    expect(await utf8.decoder.bind(response).join(), 'offline-loopback');
  });
  test('rejects external HTTP redirects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, 'http://external.invalid/redirected');
      await request.response.close();
    });
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/'));
    await expectLater(request.close(), _blocked);
  });
  testWidgets('reinstalls guard after widget binding', (tester) async {
    expect(HttpOverrides.current, same(_offline));
    await tester.runAsync(() async {
      final client = HttpClient();
      try {
        await expectLater(client.getUrl(Uri.parse('http://external.invalid/')), _blocked);
      } finally {
        client.close(force: true);
      }
    });
  });
  test('permits MockClient responses', () async {
    final client = MockClient((request) async => http.Response('synthetic model response', 200));
    addTearDown(client.close);
    final response = await client.get(Uri.parse('http://external.invalid/'));
    expect(response.body, 'synthetic model response');
  });
}
