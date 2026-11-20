import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/image_snapshots.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_app/ui/chat/widgets/artifact_card.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_app/ui/share/share_gallery.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../files/support/files_harness.dart';
import '../media/support.dart' show drawPicture;
import 'support/harness.dart';

const _session = 's1';
const _path = '/root/work/chart.png';

class _MappedFiles extends FilesChannel {
  _MappedFiles(this.source);

  final File source;
  final resolved = <String>[];

  @override
  Future<String?> resolveGuest(String path) async {
    resolved.add(path);
    return path == _path ? source.path : null;
  }
}

class _RemotePictures extends DshCarrier {
  _RemotePictures(this.source);

  final File source;
  final calls = <String>[];

  @override
  String get kind => 'snapshot-memory';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add(endpoint);
    expect(args['workspaceFileScopeId'], _session);
    expect(args['path'], _path);
    // Both revisions deliberately advertise the same freshness token.
    switch (endpoint) {
      case 'workspaceFiles/stat':
        return RpcOk({'absolutePath': _path, 'version': 'unchanged', 'bytes': await source.length()});
      case 'workspaceFiles/readBytes':
        final bytes = await source.readAsBytes();
        return RpcOk({'data': bytes, 'version': 'unchanged', 'bytes': bytes.length, 'eof': true});
      default:
        throw StateError('unexpected RPC: $endpoint');
    }
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => throw StateError('unexpected mux link');

  @override
  Future<void> close() async {}
}

class _Pictures {
  _Pictures() {
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(client.close);
  }

  final dir = Directory.systemTemp.createTempSync('turn-image-snapshot-');
  final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:9')));
  final workspace = MemoryWorkspace(files: {'chart.png': 'image'});
  late final source = File('${dir.path}/chart.png')..writeAsBytesSync(tinyPng);
  late final channel = _MappedFiles(source);
  late final files = ArtifactFiles(
    connection: HostConnection(client: client, isLocal: true),
    channel: channel,
    cacheRoot: () async => dir,
    snapshots: ImageSnapshots(root: () async => dir),
    operatingSystem: 'android',
  );

  Widget app(Widget home) => filesApp(
    home,
    workspace,
    connection: files.connection,
    overrides: [artifactFilesProvider.overrideWithValue(files)],
  );
}

Widget _reply(int turn) => SizedBox(
  width: 320,
  height: 180,
  child: MarkdownImageScope(
    sessionId: _session,
    turn: turn,
    child: const MarkdownBody(text: '![Chart]($_path)', selectable: false),
  ),
);

Future<void> _decode(WidgetTester tester, {int count = 1}) async {
  // Static placeholders do not keep pumpAndSettle alive during file I/O.
  // Build FileImage and decode it in the real-async zone once bytes arrive.
  await tester.runAsync(() async {
    for (var i = 0; i < 100 && find.byType(Image).evaluate().length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pumpAndSettle();
    }
    final images = find.byType(Image);
    expect(images, findsNWidgets(count));
    for (final element in images.evaluate().toList()) {
      final provider = (element.widget as Image).image;
      await precacheImage(provider, element).timeout(const Duration(seconds: 5));
    }
  });
  await tester.pumpAndSettle();
}

Future<void> _decodeShare(WidgetTester tester) async {
  final context = tester.element(find.byType(ShareImageScope));
  for (var i = 0; i < 100 && shareImagesPending(context) > 0; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pumpAndSettle();
    });
  }
  expect(shareImagesPending(context), 0);
  await tester.pumpAndSettle();
}

FileImage _fileImage(WidgetTester tester, Finder root) {
  final image = tester.widget<Image>(find.descendant(of: root, matching: find.byType(Image)));
  final provider = image.image;
  return (provider is ResizeImage ? provider.imageProvider : provider) as FileImage;
}

void _expectPixels(WidgetTester tester, Finder root, int width, int height) {
  final pixels = tester.widget<RawImage>(find.descendant(of: root, matching: find.byType(RawImage))).image;
  expect(pixels, isNotNull);
  expect(pixels!.width, width);
  expect(pixels.height, height);
}

Future<void> _expectPreview(
  WidgetTester tester, {
  required int turn,
  required String filePath,
  required int width,
  required int height,
}) async {
  await _decode(tester);
  final preview = find.byType(ArtifactPreviewPage);
  final artifact = tester.widget<ArtifactPreviewPage>(preview).artifact;
  expect(artifact.path, _path);
  expect(artifact.turn, turn);
  expect(artifact.snapshotImage, isTrue);
  expect(_fileImage(tester, preview).file.path, filePath);
  _expectPixels(tester, preview, width, height);
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('the same Markdown path keeps distinct turn pixels after remount and full-screen open', (tester) async {
    usePhoneView(tester);
    final pictures = _Pictures();
    final changed = (await tester.runAsync(() => drawPicture(7, 3)))!;
    final inline = find.byType(MarkdownImage);

    await tester.pumpWidget(pictures.app(Scaffold(body: _reply(1))));
    await _decode(tester);
    final firstState = tester.state(inline);
    final firstPath = _fileImage(tester, inline).file.path;
    expect(firstPath, isNot(pictures.source.path));
    _expectPixels(tester, inline, 4, 4);

    pictures.source.writeAsBytesSync(changed);
    await tester.pumpWidget(pictures.app(Scaffold(body: _reply(2))));
    await _decode(tester);
    expect(tester.state(inline), same(firstState));
    final secondPath = _fileImage(tester, inline).file.path;
    expect(secondPath, isNot(firstPath));
    _expectPixels(tester, inline, 7, 3);

    await tester.tap(inline);
    await _expectPreview(tester, turn: 2, filePath: secondPath, width: 7, height: 3);
    expect(pictures.workspace.watching('chart.png'), 0);
    Navigator.of(tester.element(find.byType(ArtifactPreviewPage))).pop();
    await tester.pumpAndSettle();

    // Dispose the widgets and Riverpod readers, not just the visible image.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await tester.pumpWidget(pictures.app(Scaffold(body: _reply(1))));
    await _decode(tester);
    expect(tester.state(inline), isNot(same(firstState)));
    expect(_fileImage(tester, inline).file.path, firstPath);
    _expectPixels(tester, inline, 4, 4);

    await tester.tap(inline);
    await _expectPreview(tester, turn: 1, filePath: firstPath, width: 4, height: 4);
    expect(pictures.workspace.watching('chart.png'), 0);
    expect(pictures.channel.resolved, [_path, _path]);
    expect(pictures.source.readAsBytesSync(), changed);
    expect(tester.takeException(), isNull);
  });

  testWidgets('artifact cards share their turn snapshot with Markdown and full-screen pixels', (tester) async {
    usePhoneView(tester);
    final pictures = _Pictures();
    final changed = (await tester.runAsync(() => drawPicture(7, 3)))!;
    final inline = find.byType(MarkdownImage);

    await tester.pumpWidget(pictures.app(Scaffold(body: _reply(1))));
    await _decode(tester);
    final firstPath = _fileImage(tester, inline).file.path;
    pictures.source.writeAsBytesSync(changed);

    for (final (turn, width, height) in [(1, 4, 4), (2, 7, 3)]) {
      final artifact = Artifact(path: _path, origin: ArtifactOrigin.delivered, turn: turn);
      expect(artifact.snapshotImage, isFalse);
      await tester.pumpWidget(
        pictures.app(
          Scaffold(
            body: Column(
              children: [
                _reply(turn),
                ArtifactCard(
                  sessionId: _session,
                  group: TurnArtifacts(turn: turn, endSeq: turn * 10, files: [artifact]),
                ),
              ],
            ),
          ),
        ),
      );
      await _decode(tester, count: 2);
      final path = _fileImage(tester, inline).file.path;
      expect(path, turn == 1 ? firstPath : isNot(firstPath));
      expect(path, isNot(pictures.source.path));
      _expectPixels(tester, inline, width, height);
      final thumb = find.byType(ArtifactThumb);
      expect(_fileImage(tester, thumb).file.path, path);
      expect(tester.widget<RawImage>(find.descendant(of: thumb, matching: find.byType(RawImage))).image, isNotNull);
      expect(tester.widget<ArtifactTile>(find.byType(ArtifactTile)).artifact.snapshotImage, isTrue);

      await tester.tap(find.descendant(of: find.byType(ArtifactCard), matching: find.text('chart.png')));
      await _expectPreview(tester, turn: turn, filePath: path, width: width, height: height);
      expect(pictures.workspace.watching('chart.png'), 0);
      Navigator.of(tester.element(find.byType(ArtifactPreviewPage))).pop();
      await tester.pumpAndSettle();
    }
    expect(pictures.channel.resolved, [_path, _path]);
    expect(tester.takeException(), isNull);
  });

  test('reply and conversation shares retain each image turn from row keys or traces', () {
    for (final useRowKeys in [true, false]) {
      final replies = [
        for (final turn in [1, 2])
          AssistantChatItem(
            id: 'a$turn',
            rowKey: useRowKeys ? 'm$turn.1' : null,
            seq: turn * 10 + 1,
            text: '![Chart]($_path)',
            reasoning: '',
          ),
      ];
      final state = ChatState(
        items: replies,
        loading: false,
        turns: [
          if (!useRowKeys)
            for (final turn in [1, 2])
              TurnTrace(turn: turn, startSeq: turn * 10, endSeq: turn * 10 + 9, start: DateTime(2026), spans: []),
        ],
      );
      final reply = shareContentForReply(state, replies.first, sessionId: _session, tools: false);
      expect(reply.blocks.whereType<ShareAnswer>().single.turn, 1);
      final conversation = shareContentForItems(state, {for (final item in replies) item.key}, tools: false);
      final answers = conversation.blocks.whereType<ShareAnswer>().toList();
      expect(answers.map((answer) => answer.turn), [1, 2]);
      expect(answers.map((answer) => shareSegments(answer.markdown).single.images.single), [_path, _path]);
    }
  });

  testWidgets('a share gallery keeps old turn pixels and reloads the same cell for a new turn', (tester) async {
    usePhoneView(tester);
    final pictures = _Pictures();
    final changed = (await tester.runAsync(() => drawPicture(7, 3)))!;
    await tester.pumpWidget(pictures.app(Scaffold(body: _reply(1))));
    await _decode(tester);
    pictures.source.writeAsBytesSync(changed);

    Widget gallery(int turn) => Scaffold(
      body: ShareImageScope(
        sessionId: _session,
        child: ShareGallery(images: [ShareUrlImage(_path, turn: turn)], width: 320),
      ),
    );
    await tester.pumpWidget(pictures.app(gallery(1)));
    await _decodeShare(tester);
    final cell = find.byKey(const ValueKey('share-image-0'));
    final firstState = tester.state(cell);
    _expectPixels(tester, find.byType(ShareGallery), 4, 4);

    await tester.pumpWidget(pictures.app(gallery(2)));
    expect(tester.state(cell), same(firstState));
    await _decodeShare(tester);
    _expectPixels(tester, find.byType(ShareGallery), 7, 3);
    expect(pictures.channel.resolved, [_path, _path]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote turns read new bytes despite an unchanged stat and an older mutable cache', (tester) async {
    final pictures = _Pictures();
    final wire = _RemotePictures(pictures.source);
    final client = DshClient.withCarrier(wire);
    addTearDown(client.close);
    final files = ArtifactFiles(
      connection: HostConnection(client: client, isLocal: false, hostId: 'snapshot-remote'),
      channel: pictures.channel,
      cacheRoot: () async => pictures.dir,
      snapshots: pictures.files.snapshots,
      operatingSystem: 'android',
    );
    final changed = (await tester.runAsync(() => drawPicture(7, 3)))!;
    const first = Artifact(path: _path, origin: ArtifactOrigin.linked, turn: 1, snapshotImage: true);
    const second = Artifact(path: _path, origin: ArtifactOrigin.linked, turn: 2, snapshotImage: true);

    await tester.runAsync(() async {
      // Seed the old per-path download cache before the turn snapshots.
      final live = await files.materialize(
        _session,
        const Artifact(path: _path, origin: ArtifactOrigin.linked, turn: 0),
      );
      expect(await live.readAsBytes(), tinyPng);
      wire.calls.clear();
      final oldSnapshot = await files.materialize(_session, first);
      expect(oldSnapshot.path, isNot(live.path));
      expect(await oldSnapshot.readAsBytes(), tinyPng);

      await pictures.source.writeAsBytes(changed);
      final newSnapshot = await files.materialize(_session, second);
      expect(newSnapshot.path, isNot(oldSnapshot.path));
      expect(await newSnapshot.readAsBytes(), changed);
      expect(await live.readAsBytes(), tinyPng);
      expect((await files.materialize(_session, first)).path, oldSnapshot.path);

      await pictures.source.delete();
      expect(await (await files.materialize(_session, first)).readAsBytes(), tinyPng);
      expect(await (await files.materialize(_session, second)).readAsBytes(), changed);
      // readFile itself stats once; snapshot materialization adds no extra stat.
      expect(wire.calls, [
        'workspaceFiles/stat',
        'workspaceFiles/readBytes',
        'workspaceFiles/stat',
        'workspaceFiles/readBytes',
      ]);
      expect(pictures.channel.resolved, isEmpty);
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('a standalone workspace preview stays live even when its turn has a snapshot', (tester) async {
    usePhoneView(tester);
    final pictures = _Pictures();
    const artifact = Artifact(path: _path, origin: ArtifactOrigin.linked, turn: 1);
    final snapshot = (await tester.runAsync(() => pictures.files.materialize(_session, artifact.withImageSnapshot())))!;
    final changed = (await tester.runAsync(() => drawPicture(7, 3)))!;
    final latest = (await tester.runAsync(() => drawPicture(9, 5, index: 1)))!;
    pictures.source.writeAsBytesSync(changed);

    expect(artifact.snapshotImage, isFalse);
    await tester.pumpWidget(pictures.app(const ArtifactPreviewPage(sessionId: _session, artifact: artifact)));
    await _decode(tester);
    final preview = find.byType(ArtifactPreviewPage);
    expect(_fileImage(tester, preview).file.path, pictures.source.path);
    _expectPixels(tester, preview, 7, 3);
    expect(pictures.workspace.watching('chart.png'), 1);

    pictures.source.writeAsBytesSync(latest);
    pictures.workspace.write('chart.png', latest);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await _decode(tester);
    _expectPixels(tester, preview, 9, 5);
    expect(snapshot.readAsBytesSync(), tinyPng);
    expect(pictures.workspace.watching('chart.png'), 1);
    expect(tester.takeException(), isNull);
  });
}
