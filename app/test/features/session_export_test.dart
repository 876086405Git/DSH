// 导出会话日志 (`/export`): the exporter fetches the Host's ZIP into the cache
// and hands it to the share sheet or Downloads; the page offers both, or says
// why this connection can't. Regenerate the goldens with
// `flutter test --update-goldens test/features/session_export_test.dart`.

import 'dart:io';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/session_export.dart';
import 'package:dsh_app/ui/features/session_export_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';

class _Channel extends FilesChannel {
  final saved = <(String, String, String)>[];

  @override
  Future<String> saveToDownloads(String hostPath, {required String name, required String mime}) async {
    saved.add((hostPath, name, mime));
    return 'Download/DSH-Go/$name';
  }
}

class _NoHttp extends DshCarrier {
  @override
  String get kind => 'relay';

  @override
  DshTracer? get tracer => null;

  @override
  bool allowsEndpoint(String endpoint) => true;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      throw UnsupportedError(endpoint);

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('no streams');

  @override
  Future<void> close() async {}
}

class _Recording extends SessionLogExporter {
  _Recording(HostConnection connection, {this.savedAt, this.failure})
    : super(connection: connection, channel: _Channel());

  final String? savedAt;
  final Object? failure;
  final calls = <String>[];

  @override
  Future<void> share(String sessionId) async => calls.add('share $sessionId');

  @override
  Future<String> saveToDownloads(String sessionId) async {
    calls.add('save $sessionId');
    if (failure case final error?) throw error;
    return savedAt ?? 'Download/DSH-Go/${sessionLogZipName(sessionId)}';
  }
}

/// The test binding answers every HttpClient request with 400; these tests
/// talk to a real local server.
class _RealHttp extends HttpOverrides {}

Future<T> _withRealHttp<T>(Future<T> Function() body) => HttpOverrides.runWithHttpOverrides(body, _RealHttp());

final _relay = fakeHost(DshClient.withCarrier(_NoHttp()), kind: HostKind.relay, label: '家里的 Mac · 远程');

Future<void> _pump(
  WidgetTester tester, {
  required List<Override> overrides,
  Brightness brightness = Brightness.light,
}) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      const SessionExportPage(sessionId: 's1'),
      brightness: brightness,
      overrides: overrides,
    ),
  );
  await pumpFrames(tester, 6);
}

void main() {
  group('exporter', () {
    late HttpServer server;
    late Directory cache;
    HostConnection host() => fakeHost(DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}'))));

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'zip');
        request.response.add([0x50, 0x4b, 0x05, 0x06]);
        await request.response.close();
      });
      cache = await Directory.systemTemp.createTemp('export_test');
    });

    tearDown(() async {
      await server.close(force: true);
      await cache.delete(recursive: true);
    });

    test(
      'share: the ZIP keeps its bytes and official name',
      () => _withRealHttp(() async {
        final shared = <ShareParams>[];
        final exporter = SessionLogExporter(
          connection: host(),
          channel: _Channel(),
          share: (params) async => shared.add(params),
          cacheRoot: () async => cache,
        );
        expect(exporter.supported, isTrue);
        await exporter.share('s/1');
        final params = shared.single;
        expect(await params.files!.single.readAsBytes(), [0x50, 0x4b, 0x05, 0x06]);
        expect(params.files!.single.mimeType, 'application/zip');
        expect(params.fileNameOverrides, ['dsh-session-s_1.zip']);
      }),
    );

    test(
      'save: copies it into Downloads as a ZIP',
      () => _withRealHttp(() async {
        final channel = _Channel();
        final exporter = SessionLogExporter(connection: host(), channel: channel, cacheRoot: () async => cache);
        expect(await exporter.saveToDownloads('s1'), 'Download/DSH-Go/dsh-session-s1.zip');
        expect(channel.saved.single.$2, 'dsh-session-s1.zip');
        expect(channel.saved.single.$3, 'application/zip');
      }),
    );

    test('errors read as sentences', () {
      expect(sessionExportErrorText(const DshRemoteException('session-export/unsupported', 'x')), contains('中转'));
      expect(sessionExportErrorText(const DshRemoteException('session-export/http-500', 'x')), '没能导出');
      expect(sessionExportErrorText(const DshTransportException('down')), '没能连上引擎');
    });
  });

  group('page', () {
    testWidgets('share and save go to the exporter, one at a time', (tester) async {
      final exporter = _Recording(fakeConnection);
      await _pump(
        tester,
        overrides: [
          activeConnectionProvider.overrideWithValue(AsyncData(fakeConnection)),
          sessionLogExporterProvider.overrideWithValue(exporter),
        ],
      );
      await tester.tap(find.text('分享'));
      await pumpFrames(tester);
      await tester.tap(find.text('存到「下载」'));
      await pumpFrames(tester);
      expect(exporter.calls, ['share s1', 'save s1']);
      expect(find.text('已存到 Download/DSH-Go/dsh-session-s1.zip'), findsOneWidget);
      expect(find.text('存进 下载/DSH-Go'), findsOneWidget);
    });

    List<Override> onHarmony(_Recording exporter) => [
      operatingSystemProvider.overrideWithValue('ohos'),
      activeConnectionProvider.overrideWithValue(AsyncData(fakeConnection)),
      sessionLogExporterProvider.overrideWithValue(exporter),
    ];

    testWidgets('HarmonyOS: asks where, and says 已保存 instead of the URI', (tester) async {
      final exporter = _Recording(fakeConnection, savedAt: 'file://docs/storage/Users/currentUser/Download/s1.zip');
      await _pump(tester, overrides: onHarmony(exporter));
      expect(find.text('选择保存位置'), findsOneWidget);
      expect(find.text('存到「下载」'), findsNothing);
      expect(find.text('存进 下载/DSH-Go'), findsNothing);
      await tester.tap(find.text('保存到文件'));
      await pumpFrames(tester);
      expect(exporter.calls, ['save s1']);
      expect(find.text('已保存'), findsOneWidget);
      expect(find.textContaining('file://'), findsNothing);
    });

    testWidgets('HarmonyOS: backing out of the window says nothing; a real failure still does', (tester) async {
      await _pump(
        tester,
        overrides: onHarmony(_Recording(fakeConnection, failure: PlatformException(code: 'cancelled'))),
      );
      await tester.tap(find.text('保存到文件'));
      await pumpFrames(tester);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('已保存'), findsNothing);

      await _pump(
        tester,
        overrides: onHarmony(_Recording(fakeConnection, failure: PlatformException(code: 'failed'))),
      );
      await tester.tap(find.text('保存到文件'));
      await pumpFrames(tester);
      expect(find.text('没能导出'), findsOneWidget);
    });

    testWidgets('the relay tunnel explains instead of offering buttons', (tester) async {
      await _pump(tester, overrides: [activeConnectionProvider.overrideWithValue(AsyncData(_relay))]);
      expect(find.text('这个连接导不了'), findsOneWidget);
      expect(find.text('分享'), findsNothing);
    });

    testWidgets('offline', (tester) async {
      await _pump(tester, overrides: [activeConnectionProvider.overrideWithValue(const AsyncData(null))]);
      expect(find.text('分享'), findsNothing);
    });
  });

  setUpAll(loadTestFonts);
  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('golden ($mode)', (tester) async {
      await _pump(
        tester,
        brightness: brightness,
        overrides: [activeConnectionProvider.overrideWithValue(AsyncData(fakeConnection))],
      );
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/session_export_$mode.png'));
    });
  }
}
