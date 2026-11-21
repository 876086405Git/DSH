// Explicit runner entry: default test/ discovery does not run suites twice.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../tooling/companion/offline_http.dart';
import '../test/companion_auxiliary_api_test.dart' as auxiliary;
import '../test/companion_followup_store_test.dart' as followup;
import '../test/companion_memory_flow_test.dart' as flow;
import '../test/companion_memory_chat_replay_test.dart' as chat_replay;
import '../test/companion_memory_control_anchor_test.dart' as control_anchors;
import '../test/companion_memory_delete_lineage_test.dart' as delete_lineage;
import '../test/companion_memory_merge_rules_test.dart' as merge_rules;
import '../test/companion_memory_merge_test.dart' as merge;
import '../test/companion_memory_rules_test.dart' as rules;
import '../test/companion_memory_store_test.dart' as store;
import '../test/companion_migration_recovery_test.dart' as migration;
import '../test/companion_prompt_commit_test.dart' as prompt_commit;
import '../test/companion_prompt_context_test.dart' as prompt_context;

final _offline = CompanionOfflineHttpOverrides();
final _blocked = throwsA(
  isA<SocketException>().having((error) => error.message, 'message', startsWith('offline companion replay')),
);

void main() {
  HttpOverrides.global = _offline;
  setUp(() => HttpOverrides.global = _offline);
  group('offline', () {
    test('rejects external HTTP before DNS', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      for (final host in ['external.invalid', 'localhost', '192.0.2.1']) {
        await expectLater(client.getUrl(Uri.parse('http://$host/')), _blocked);
      }
      // A local proxy must not turn an external original URL into permission.
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
  });
  for (final suite in <String, void Function()>{
    'test/companion_memory_store_test.dart': store.main,
    'test/companion_migration_recovery_test.dart': migration.main,
    'test/companion_memory_flow_test.dart': flow.main,
    'test/companion_memory_chat_replay_test.dart': chat_replay.main,
    'test/companion_memory_control_anchor_test.dart': control_anchors.main,
    'test/companion_memory_delete_lineage_test.dart': delete_lineage.main,
    'test/companion_memory_rules_test.dart': rules.main,
    'test/companion_followup_store_test.dart': followup.main,
    'test/companion_memory_merge_test.dart': merge.main,
    'test/companion_memory_merge_rules_test.dart': merge_rules.main,
    'test/companion_prompt_context_test.dart': prompt_context.main,
    'test/companion_prompt_commit_test.dart': prompt_commit.main,
    'test/companion_auxiliary_api_test.dart': auxiliary.main,
  }.entries) {
    group(suite.key, suite.value);
  }
}
