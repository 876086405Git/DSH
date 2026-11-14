// The artifact card's actions reach Android through platform channels
// (`dsh/files` for open / save, share_plus for share), mocked here; and a
// remote Host's file is downloaded once into the cache, again on a new
// version.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/widgets/artifact_card.dart';
import 'package:dsh_app/ui/share/share_card.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_app/ui/share/share_image_page.dart';
import 'package:dsh_app/ui/share/share_panel.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _files = MethodChannel('dsh/files');
const _share = MethodChannel('dev.fluttercommunity.plus/share');

/// Records `dsh/files` and share calls; answers like the Kotlin side would.
class _Android {
  final calls = <MethodCall>[];
  final shares = <MethodCall>[];
  Object? openError;

  void install(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_files, (call) async {
      calls.add(call);
      final args = (call.arguments as Map).cast<String, Object?>();
      switch (call.method) {
        case 'resolveGuest':
          final path = args['path']! as String;
          return path.contains('missing') ? null : '/data/user/0/app/files/runtime/rootfs$path';
        case 'open':
          if (openError case final error?) throw error;
          return null;
        case 'saveToDownloads':
          return 'Download/DSH-Go/${args['name']}';
        case 'listOutputs':
          return const <Object?>[];
        case 'pdfInfo':
          return [
            {'width': 595, 'height': 842},
            {'width': 595, 'height': 842},
          ];
        case 'pdfPage':
          return Uint8List(0);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_share, (call) async {
      shares.add(call);
      return 'dev.fluttercommunity.plus/share/success';
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(_files, null);
      messenger.setMockMethodCallHandler(_share, null);
    });
  }

  List<String> get methods => [for (final c in calls) c.method];
  Map<String, Object?> last(String method) =>
      (calls.lastWhere((c) => c.method == method).arguments as Map).cast<String, Object?>();
}

const _pdf = Artifact(
  path: '/root/workspace/out/report.pdf',
  origin: ArtifactOrigin.delivered,
  turn: 1,
  description: '2026 Q3 销售汇总',
);

const _zip = Artifact(path: '/root/workspace/素材.zip', origin: ArtifactOrigin.written, turn: 1);

const _docx = Artifact(path: '/home/me/out/纪要.docx', origin: ArtifactOrigin.linked, turn: 1);

Widget _card(List<Artifact> files, {HostConnection? connection}) => testApp(
  Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: ArtifactCard(
        sessionId: 's1',
        group: TurnArtifacts(turn: 1, endSeq: 9, files: files),
      ),
    ),
  ),
  overrides: [activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(connection ?? fakeConnection))],
);

Future<void> _menuAction(WidgetTester tester, String label, {int row = 0}) async {
  await tester.tap(find.byTooltip('更多操作').at(row));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// workspaceFiles/stat + readBytes over a non-HTTP carrier.
class _RemoteCarrier extends DshCarrier {
  _RemoteCarrier(this.content);

  Uint8List content;
  String version = 'v1';
  final calls = <String>[];

  /// Completes `officeToPdf/render` (null: answers at once).
  Completer<void>? converting;

  @override
  String get kind => 'memory';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add(endpoint);
    final stat = {'absolutePath': '/home/me/out/a.png', 'version': version, 'bytes': content.length};
    if (endpoint == 'officeToPdf/render') {
      await converting?.future;
      return RpcOk({
        ...stat,
        'offset': 0,
        'eof': true,
        'data': base64Encode(utf8.encode('%PDF-1.7 $version')),
        'missingFonts': const <String>[],
        'generation': 'g1',
      });
    }
    return switch (endpoint) {
      'workspaceFiles/stat' => RpcOk(stat),
      'workspaceFiles/readBytes' => RpcOk({...stat, 'offset': 0, 'data': base64Encode(content), 'eof': true}),
      _ => const RpcError(DshRemoteException('gateway/not-found', 'missing')),
    };
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('no streams');

  @override
  Future<void> close() async {}
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('open, share, save and copy go through the platform channels', (tester) async {
    usePhoneView(tester);
    final android = _Android()..install(tester);
    mockClipboard(tester);
    await tester.pumpWidget(_card([_pdf]));
    await tester.pumpAndSettle();
    expect(find.text('交付了 1 个文件'), findsOneWidget);
    expect(find.text('2026 Q3 销售汇总'), findsOneWidget);

    await _menuAction(tester, '打开');
    expect(android.methods, ['resolveGuest', 'open']);
    expect(android.last('resolveGuest'), {'path': _pdf.path});
    expect(android.last('open'), {
      'path': '/data/user/0/app/files/runtime/rootfs${_pdf.path}',
      'name': 'report.pdf',
      'mime': 'application/pdf',
      'chooser': false,
    });

    await _menuAction(tester, '用其他应用打开');
    expect(android.last('open')['chooser'], isTrue);

    // 分享: the share panel, whose 文件 sends the file itself.
    await _menuAction(tester, '分享');
    expect(find.byType(SharePanel), findsOneWidget);
    expect(find.byKey(const ValueKey('share-to-link')), findsNothing, reason: 'links are for conversations');
    expect(find.byKey(const ValueKey('share-to-text')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('share-to-image')));
    await tester.pumpAndSettle();
    expect(find.byType(ShareImagePage), findsOneWidget);
    expect(tester.widget<ShareCard>(find.byType(ShareCard)).content.blocks.single, isA<ShareFile>());
    await tester.tap(find.descendant(of: find.byType(SharePanel), matching: find.byTooltip('返回')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('share-to-file')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byKey(const ValueKey('share-file-row')), matching: find.text('report.pdf')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('share-file-format')), findsNothing, reason: 'the file is sent as it is');
    await tester.tap(find.byKey(const ValueKey('share-file-send')));
    await tester.pumpAndSettle();
    final share = (android.shares.single.arguments as Map).cast<String, Object?>();
    expect(share['paths'], ['/data/user/0/app/files/runtime/rootfs${_pdf.path}']);
    expect(share['mimeTypes'], ['application/pdf']);
    Navigator.of(tester.element(find.byType(SharePanel))).pop();
    await tester.pumpAndSettle();

    await _menuAction(tester, '存到「下载」');
    expect(android.last('saveToDownloads'), {
      'path': '/data/user/0/app/files/runtime/rootfs${_pdf.path}',
      'name': 'report.pdf',
      'mime': 'application/pdf',
    });
    expect(find.text('已存到 下载/DSH-Go/report.pdf'), findsOneWidget);
    // Success feedback stays five seconds, then the description is back.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('2026 Q3 销售汇总'), findsOneWidget);

    await _menuAction(tester, '复制路径');
    expect(find.text('已复制路径'), findsOneWidget);
  });

  testWidgets('tapping a file Android must open opens it; failures stay on the row', (tester) async {
    usePhoneView(tester);
    final android = _Android()
      ..openError = PlatformException(code: 'no_app')
      ..install(tester);
    await tester.pumpWidget(_card([_zip]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('素材.zip'));
    await tester.pumpAndSettle();
    expect(android.methods, ['resolveGuest', 'open']);
    expect(android.last('open')['mime'], 'application/zip');
    expect(find.text('手机上没有能打开这类文件的应用'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('手机上没有能打开这类文件的应用'), findsOneWidget);

    android.openError = null;
    await tester.tap(find.text('素材.zip'));
    await tester.pumpAndSettle();
    expect(find.text('压缩包 · ZIP'), findsOneWidget);
  });

  testWidgets('a PDF previews in the app, page by page', (tester) async {
    usePhoneView(tester);
    final android = _Android()..install(tester);
    await tester.pumpWidget(_card([_pdf]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('report.pdf'));
    await tester.pumpAndSettle();
    expect(android.methods.take(3), ['resolveGuest', 'pdfInfo', 'pdfPage']);
    final host = '/data/user/0/app/files/runtime/rootfs${_pdf.path}';
    expect(android.last('pdfInfo'), {'path': host});
    expect(
      [
        for (final c in android.calls)
          if (c.method == 'pdfPage') (c.arguments as Map)['page'],
      ],
      [0, 1],
      reason: 'both pages are on screen',
    );
    await tester.drag(find.byType(ListView), const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(find.text('共 2 页'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(android.methods.last, 'pdfClose');
  });

  testWidgets('an Office file previews as the Host\'s PDF; apps stay a tap away', (tester) async {
    usePhoneView(tester);
    final android = _Android()..install(tester);
    final cache = Directory.systemTemp.createTempSync('office');
    addTearDown(() => cache.deleteSync(recursive: true));
    final carrier = _RemoteCarrier(Uint8List(4))..converting = Completer();
    final remote = HostConnection(client: DshClient.withCarrier(carrier), label: '工作站', isLocal: false, hostId: 'h1');
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ArtifactCard(
            sessionId: 's1',
            group: const TurnArtifacts(turn: 1, endSeq: 9, files: [_docx]),
          ),
        ),
        overrides: [
          activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(remote)),
          artifactFilesProvider.overrideWithValue(
            ArtifactFiles(connection: remote, channel: const FilesChannel(), cacheRoot: () async => cache),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('纪要.docx'));
    await pumpFrames(tester, 4);
    expect(find.text('正在转换为 PDF 预览…'), findsOneWidget);
    expect(find.text('用手机上的应用打开'), findsOneWidget);

    carrier.converting!.complete();
    // The PDF is written to the cache with real file IO; under a loaded full run that can take a while.
    for (var i = 0; i < 100 && !android.methods.contains('pdfInfo'); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await pumpFrames(tester, 2);
    expect(carrier.calls, contains('officeToPdf/render'));
    expect(android.methods, contains('pdfInfo'));
    final info = android.last('pdfInfo');
    expect(info['path'], endsWith('/纪要.pdf'));
    expect(find.text('正在转换为 PDF 预览…'), findsNothing);
  });

  testWidgets('a file that is gone says so', (tester) async {
    usePhoneView(tester);
    final android = _Android()..install(tester);
    const gone = Artifact(path: '/root/workspace/missing.zip', origin: ArtifactOrigin.written, turn: 1);
    await tester.pumpWidget(_card([gone]));
    await tester.pumpAndSettle();
    await _menuAction(tester, '分享');
    await tester.tap(find.byKey(const ValueKey('share-to-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('share-file-send')));
    await tester.pumpAndSettle();
    expect(android.methods, ['resolveGuest']);
    expect(android.shares, isEmpty);
    expect(find.text('找不到这个文件了，可能已被删除或移走'), findsOneWidget);
  });

  testWidgets('files already in Downloads offer no save; more than four collapse', (tester) async {
    usePhoneView(tester);
    _Android().install(tester);
    final files = [
      const Artifact(path: '$phoneOutputDir/summary.xlsx', origin: ArtifactOrigin.phoneOutput, turn: 1, bytes: 18432),
      for (final name in ['a.pdf', 'b.docx', 'c.pptx', 'd.zip', 'e.mp4'])
        Artifact(path: '/root/workspace/$name', origin: ArtifactOrigin.written, turn: 1),
    ];
    await tester.pumpWidget(_card(files));
    await tester.pumpAndSettle();
    expect(find.text('生成了 6 个文件'), findsOneWidget);
    expect(find.byType(ArtifactTile), findsNWidgets(4));
    expect(find.text('表格 · XLSX · 18.0 KB'), findsOneWidget);
    await tester.tap(find.text('全部 6 个文件'));
    await tester.pumpAndSettle();
    expect(find.byType(ArtifactTile), findsNWidgets(6));
    expect(find.text('收起'), findsOneWidget);

    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
    expect(find.text('已在手机的「下载」里'), findsOneWidget);
    expect(find.text('存到「下载」'), findsNothing);
    expect(find.text('分享'), findsOneWidget);
  });

  group('remote Host', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late Directory cache;
    late _RemoteCarrier carrier;
    late ArtifactFiles files;
    final saved = <MethodCall>[];

    setUp(() {
      cache = Directory.systemTemp.createTempSync('artifacts');
      carrier = _RemoteCarrier(Uint8List.fromList([1, 2, 3]));
      saved.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_files, (call) async {
        saved.add(call);
        return 'Download/DSH-Go/a (2).png';
      });
      files = ArtifactFiles(
        connection: HostConnection(client: DshClient.withCarrier(carrier), label: '工作站', isLocal: false, hostId: 'h1'),
        channel: const FilesChannel(),
        cacheRoot: () async => cache,
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_files, null);
      cache.deleteSync(recursive: true);
    });

    const image = Artifact(path: '/home/me/out/a.png', origin: ArtifactOrigin.linked, turn: 2);

    test('downloads once per version into the cache, then hands Android the copy', () async {
      final progress = <double?>[];
      final first = await files.materialize('s1', image, onProgress: progress.add);
      expect(first.path, startsWith('${cache.path}/artifacts/'));
      expect(first.path, endsWith('/a.png'));
      expect(first.readAsBytesSync(), [1, 2, 3]);
      expect(progress.last, 1.0);
      expect(carrier.calls, ['workspaceFiles/stat', 'workspaceFiles/stat', 'workspaceFiles/readBytes']);

      carrier.calls.clear();
      final again = await files.materialize('s1', image);
      expect(again.path, first.path);
      expect(carrier.calls, ['workspaceFiles/stat'], reason: 'same version: cached');

      carrier
        ..version = 'v2'
        ..content = Uint8List.fromList([9, 9]);
      carrier.calls.clear();
      final fresh = await files.materialize('s1', image);
      expect(fresh.readAsBytesSync(), [9, 9]);
      expect(carrier.calls.last, 'workspaceFiles/readBytes');

      final where = await files.saveToDownloads('s1', image);
      expect(where, 'Download/DSH-Go/a (2).png');
      expect(saved.single.method, 'saveToDownloads');
      expect((saved.single.arguments as Map)['path'], fresh.path);
      expect((saved.single.arguments as Map)['mime'], 'image/png');
    });

    test('Office files: the Host\'s PDF, converted once per version', () async {
      expect(files.canConvertOffice, isTrue);
      final pdf = await files.officePdf('s1', _docx);
      expect(pdf.path, endsWith('/纪要.pdf'));
      expect(utf8.decode(pdf.readAsBytesSync()), '%PDF-1.7 v1');
      carrier.calls.clear();
      await files.officePdf('s1', _docx);
      expect(carrier.calls, ['workspaceFiles/stat']);
      carrier.version = 'v2';
      final again = await files.officePdf('s1', _docx);
      expect(utf8.decode(again.readAsBytesSync()), '%PDF-1.7 v2');
    });

    test('thumbnails skip big remote images and SVGs', () async {
      expect(await files.thumbnail('s1', '/home/me/out/a.svg'), isNull);
      expect(await files.thumbnail('s1', '/home/me/out/a.pdf'), isNull);
      expect(await files.thumbnail('s1', image.path), isA<FileImage>());
      carrier.content = Uint8List(maxThumbnailBytes + 1);
      carrier.version = 'big';
      expect(await files.thumbnail('s1', image.path), isNull);
    });

    test('errors read as sentences', () {
      expect(artifactErrorText(const ArtifactError('missing')), '找不到这个文件了，可能已被删除或移走');
      expect(artifactErrorText(const DshRemoteException('workspace-file/too-large', 'x')), '文件太大，这个连接传不过来');
      expect(artifactErrorText(PlatformException(code: 'permission')), '没有存储权限，存不进「下载」');
      expect(artifactErrorText(const DshTransportException('down')), '没能连上引擎');
    });
  });
}
