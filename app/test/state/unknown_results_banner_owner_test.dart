import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/ask_ai.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/unknown_results.dart';
import 'package:dsh_app/ui/chat/widgets/unknown_results_banner.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show testApp;

final _fixture = jsonDecode(
  File('../packages/dsh_client/test/fixtures/lifecycle-real-unknown.json').readAsStringSync(),
) as Map<String, dynamic>;
final _session = _fixture['sessionId'] as String;
Map<String, dynamic> _state(String key) => jsonDecode(jsonEncode(_fixture[key])) as Map<String, dynamic>;

class _Host extends Notifier<AsyncValue<HostConnection?>> {
  @override
  AsyncValue<HostConnection?> build() => const AsyncData(null);
  void use(HostConnection connection) => state = AsyncData(connection);
}

final _host = NotifierProvider<_Host, AsyncValue<HostConnection?>>(_Host.new);

class _Chat extends ChatController {
  _Chat(super.sessionId);
  @override
  ChatState build() => const ChatState(loading: false);
}

void main() {
  for (final mode in ['stable', 'dialog-switch', 'refresh-switch', 'refresh-away-back', 'boot', 'calls', 'removed']) {
    testWidgets('unknown acknowledgement owner: $mode', (tester) async {
      // Real HttpClient is needed: the Flutter test default intentionally returns 400.
      HttpOverrides.global = null;
      final requests = <String>[];
      final entered = Completer<void>();
      final release = Completer<void>();
      late HttpServer server;
      late DshClient client;
      late UnknownResults seen;
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          requests.add(request.method);
          await utf8.decodeStream(request);
          if (requests.length == 2) {
            entered.complete();
            await release.future;
          }
          final value = _state(request.method == 'POST' ? 'acknowledged' : 'unknown');
          if (requests.length >= 2 && mode == 'boot') value['bootId'] = 'replacement-boot';
          if (requests.length >= 2 && mode == 'calls') {
            final calls = value['calls'] as List;
            final added = Map<String, dynamic>.from(calls.last as Map);
            added['callSeq'] = (added['callSeq'] as int) + 1000;
            calls.add(added);
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(value));
          await request.response.close();
        });
        client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
        seen = UnknownResults(client, await client.getLifecycleStatus(_session));
      });
      final replacement = DshClient(DshConnection(Uri.parse('http://127.0.0.1:9')));
      final original = HostConnection(client: client, isLocal: true);
      final other = HostConnection(client: replacement, isLocal: true);
      await tester.pumpWidget(
        testApp(
          Scaffold(body: UnknownResultsBanner(sessionId: _session)),
          overrides: [
            activeConnectionProvider.overrideWith((ref) => ref.watch(_host)),
            unknownResultsProvider(_session).overrideWith((ref) async => seen),
            chatProvider.overrideWith2(_Chat.new),
            askAiAvailableProvider.overrideWithValue(false),
          ],
        ),
      );
      final container = ProviderScope.containerOf(tester.element(find.byType(UnknownResultsBanner)));
      container.read(_host.notifier).use(original);
      await tester.pumpAndSettle();
      await tester.tap(find.text(appL10n.harmonyUnknownResultsReview));
      await tester.pumpAndSettle();
      if (mode == 'dialog-switch') {
        container.read(_host.notifier).use(other);
        await tester.pump();
      }
      await tester.tap(find.text(appL10n.harmonyUnknownResultsContinue));
      await tester.pumpAndSettle();
      if (mode != 'dialog-switch') {
        for (var attempt = 0; !entered.isCompleted && attempt < 500; attempt++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
        expect(entered.isCompleted, isTrue, reason: 'refresh GET reached the real server');
        if (mode.startsWith('refresh-')) {
          container.read(_host.notifier).use(other);
          await tester.pump();
          if (mode == 'refresh-away-back') {
            container.read(_host.notifier).use(original);
            await tester.pump();
          }
        }
        if (mode == 'removed') await tester.pumpWidget(const SizedBox());
      }
      release.complete();
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      final errors = tester.takeException();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await client.close();
        await replacement.close();
        await server.close(force: true);
      });
      expect(errors, isNull);
      expect(
        requests.where((method) => method == 'POST').length,
        mode == 'stable' ? 1 : 0,
        reason: 'Only the unchanged, still-mounted confirmation owner may acknowledge.',
      );
    });
  }
}
