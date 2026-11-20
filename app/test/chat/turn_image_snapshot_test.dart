import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/image_snapshots.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_app/ui/chat/widgets/artifact_card.dart';
import 'package:dsh_app/ui/share/share_card.dart';
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
  _Pictures([WidgetTester? tester]) {
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(client.close);
    if (tester != null) {
      addTearDown(
        () => tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }),
      );
    }
  }

  final dir = Directory.systemTemp.createTempSync('turn-image-snapshot-');
  final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:9')));
  final workspace = MemoryWorkspace(files: {'chart.png': 'image'});
  late final source = File('${dir.path}/chart.png')..writeAsBytesSync(tinyPng);
  late final channel = _MappedFiles(source);
  late final snapshots = ImageSnapshots(root: () async => dir);
  late final files = ArtifactFiles(
    connection: HostConnection(client: client, isLocal: true),
    channel: channel,
    cacheRoot: () async => dir,
    snapshots: snapshots,
    operatingSystem: 'android',
  );

  Widget app(Widget home) => filesApp(
    home,
    workspace,
    connection: files.connection,
    overrides: [artifactFilesProvider.overrideWithValue(files)],
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );
}

Widget _reply(int turn) => SizedBox(
  width: 320,
  child: MarkdownImageScope(
    sessionId: _session,
    turn: turn,
    child: const MarkdownBody(text: '![Chart]($_path)', selectable: false),
  ),
);

Future<void> _decode(WidgetTester tester, {required Finder root, int count = 1}) async {
  final images = find.descendant(of: root, matching: find.byType(Image));
  // Keep file I/O and FileImage construction in real async. A transition can
  // still expose the previous route's Image, so callers select their own root.
  final decoded = await tester.runAsync(() async {
    for (var i = 0; i < 250; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (images.evaluate().length == count) {
        for (final element in images.evaluate().toList()) {
          final provider = (element.widget as Image).image;
          await precacheImage(provider, element).timeout(const Duration(seconds: 5));
        }
        await tester.pump();
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return false;
  });
  expect(decoded, isTrue, reason: 'the target images must load before leaving real async');
  expect(images, findsNWidgets(count));
  await _settle(tester);
}

Future<void> _decodeShare(WidgetTester tester) async {
  final context = tester.element(find.byType(ShareImageScope));
  final decoded = await tester.runAsync(() async {
    for (var i = 0; i < 250; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (shareImagesPending(context) == 0) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return false;
  });
  expect(decoded, isTrue);
  expect(shareImagesPending(context), 0);
  await _settle(tester);
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
  final preview = find.byType(ArtifactPreviewPage);
  await _decode(tester, root: preview);
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
    final pictures = _Pictures(tester);
    final changed = (await tester.runAsync(() => drawPicture(7, 3)))!;
    final inline = find.byType(MarkdownImage);

    await tester.pumpWidget(pictures.app(Scaffold(body: _reply(1))));
    await _decode(tester, root: find.byType(MarkdownImage));
    final firstState = tester.state(inline);
    final firstPath = _fileImage(tester, inline).file.path;
    expect(firstPath, isNot(pictures.source.path));
    _expectPixels(tester, inline, 4, 4);

    pictures.source.writeAsBytesSync(changed);
    await tester.pumpWidget(pictures.app(Scaffold(body: _reply(2))));
    await _decode(tester, root: find.byType(MarkdownImage));
    expect(tester.state(inline), same(firstState));
    final secondPath = _fileImage(tester, inline).file.path;
    expect(secondPath, isNot(firstPath));
    _expectPixels(tester, inline, 7, 3);

    await tester.tap(inline);
    await _expectPreview(tester, turn: 2, filePath: secondPath, width: 7, height: 3);
    expect(pictures.workspace.watching('chart.png'), 0);
    Navigator.of(tester.element(find.byType(ArtifactPreviewPage))).pop();
    await _settle(tester);

    // Dispose the widgets and Riverpod readers, not just the visible image.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await tester.pumpWidget(pictures.app(Scaffold(body: _reply(1))));
    await _decode(tester, root: find.byType(MarkdownImage));
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
    final pictures = _Pictures(tester);
    final changed = (await tester.runAsync(() => drawPicture(7, 3)))!;
    final inline = find.byType(MarkdownImage);

    await tester.pumpWidget(pictures.app(Scaffold(body: _reply(1))));
    await _decode(tester, root: find.byType(MarkdownImage));
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
      await _decode(tester, root: find.byType(Scaffold), count: 2);
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
      await _settle(tester);
    }
    // Thumbnail and inline readers have different byte limits and can race
    // their first read. Their common immutable content, not a mock call count,
    // is the contract: all pixel/path assertions above must match per turn.
    expect(pictures.channel.resolved.toSet(), {_path});
    expect(pictures.channel.resolved.length, inInclusiveRange(2, 3));
    await tester.runAsync(() async {
      final payloads = await Directory('${pictures.dir.path}/image-snapshots/contents').list().toList();
      expect(payloads.whereType<File>(), hasLength(2));
    });
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

  testWidgets('HTML share images keep their turn while unversioned and offline cards remain usable', (tester) async {
    usePhoneView(tester);
    final pictures = _Pictures(tester);
    final changed = (await tester.runAsync(() => drawPicture(7, 3)))!;
    const html = '<img src="$_path">';
    expect(shareSegments(html).single.isImages, isFalse);
    await tester.pumpWidget(
      pictures.app(
        const Scaffold(
          body: MarkdownImageScope(
            sessionId: _session,
            turn: 1,
            child: MarkdownBody(text: html, selectable: false),
          ),
        ),
      ),
    );
    await _decode(tester, root: find.byType(MarkdownImage));
    final inline = find.byType(MarkdownImage);
    final oldPath = _fileImage(tester, inline).file.path;
    _expectPixels(tester, inline, 4, 4);
    pictures.source.writeAsBytesSync(changed);

    for (final (turn, width, height) in [(1, 4, 4), (2, 7, 3), (null, 7, 3)]) {
      await tester.pumpWidget(
        pictures.app(
          Scaffold(
            body: SingleChildScrollView(
              child: ShareCard(
                content: ShareContent(
                  sessionId: _session,
                  blocks: [ShareAnswer(html, turn: turn)],
                ),
              ),
            ),
          ),
        ),
      );
      await _decode(tester, root: find.byType(MarkdownImage));
      expect(find.byType(ShareGallery), findsNothing);
      final scope = MarkdownImageScope.maybeOf(tester.element(inline));
      expect(scope?.sessionId, _session);
      expect(scope?.turn, turn);
      _expectPixels(tester, inline, width, height);
      final path = _fileImage(tester, inline).file.path;
      if (turn == 1) {
        expect(path, oldPath);
      } else if (turn == 2) {
        expect(path, isNot(oldPath));
        expect(path, isNot(pictures.source.path));
      } else {
        expect(path, pictures.source.path);
      }
    }
    expect(pictures.channel.resolved, [_path, _path, _path]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final data = Uri.dataFromBytes(tinyPng, mimeType: 'image/png');
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ShareCard(content: ShareContent(blocks: [ShareAnswer('<img src="$data">')])),
        ),
        overrides: [
          artifactFilesProvider.overrideWithValue(
            ArtifactFiles(
              connection: null,
              channel: pictures.channel,
              cacheRoot: () async => pictures.dir,
              snapshots: pictures.snapshots,
            ),
          ),
        ],
      ),
    );
    await _decode(tester, root: find.byType(MarkdownImage));
    expect(MarkdownImageScope.maybeOf(tester.element(inline)), isNull);
    _expectPixels(tester, inline, 4, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a share gallery keeps old turn pixels and reloads the same cell for a new turn', (tester) async {
    usePhoneView(tester);
    final pictures = _Pictures(tester);
    final changed = (await tester.runAsync(() => drawPicture(7, 3)))!;
    await tester.pumpWidget(pictures.app(Scaffold(body: _reply(1))));
    await _decode(tester, root: find.byType(MarkdownImage));
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

  test('remote turns read new bytes despite an unchanged stat and an older mutable cache', () async {
    final pictures = _Pictures();
    final wire = _RemotePictures(pictures.source);
    final client = DshClient.withCarrier(wire);
    addTearDown(client.close);
    final files = ArtifactFiles(
      connection: HostConnection(client: client, isLocal: false, hostId: 'snapshot-remote'),
      channel: pictures.channel,
      cacheRoot: () async => pictures.dir,
      snapshots: pictures.snapshots,
      operatingSystem: 'android',
    );
    // This case checks byte transport, not decoding: no widget fake-async zone.
    final original = Uint8List.fromList([1, 2, 3]);
    final changed = Uint8List.fromList([7, 8, 9]);
    pictures.source.writeAsBytesSync(original);
    const first = Artifact(path: _path, origin: ArtifactOrigin.linked, turn: 1, snapshotImage: true);
    const second = Artifact(path: _path, origin: ArtifactOrigin.linked, turn: 2, snapshotImage: true);

    // Seed the old per-path download cache before the turn snapshots.
    final live = await files.materialize(_session, const Artifact(path: _path, origin: ArtifactOrigin.linked, turn: 0));
    expect(await live.readAsBytes(), original);
    wire.calls.clear();
    final oldSnapshot = await files.materialize(_session, first);
    expect(oldSnapshot.path, isNot(live.path));
    expect(await oldSnapshot.readAsBytes(), original);

    await pictures.source.writeAsBytes(changed);
    final newSnapshot = await files.materialize(_session, second);
    expect(newSnapshot.path, isNot(oldSnapshot.path));
    expect(await newSnapshot.readAsBytes(), changed);
    expect(await live.readAsBytes(), original);
    expect((await files.materialize(_session, first)).path, oldSnapshot.path);

    await pictures.source.delete();
    expect(await (await files.materialize(_session, first)).readAsBytes(), original);
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

  testWidgets('a standalone workspace preview stays live even when its turn has a snapshot', (tester) async {
    usePhoneView(tester);
    final pictures = _Pictures(tester);
    const artifact = Artifact(path: _path, origin: ArtifactOrigin.linked, turn: 1);
    final snapshot = (await tester.runAsync(() => pictures.files.materialize(_session, artifact.withImageSnapshot())))!;
    final changed = (await tester.runAsync(() => drawPicture(7, 3)))!;
    final latest = (await tester.runAsync(() => drawPicture(9, 5, index: 1)))!;
    pictures.source.writeAsBytesSync(changed);

    expect(artifact.snapshotImage, isFalse);
    await tester.pumpWidget(pictures.app(const ArtifactPreviewPage(sessionId: _session, artifact: artifact)));
    final preview = find.byType(ArtifactPreviewPage);
    await _decode(tester, root: preview);
    expect(_fileImage(tester, preview).file.path, pictures.source.path);
    _expectPixels(tester, preview, 7, 3);
    expect(pictures.workspace.watching('chart.png'), 1);

    pictures.source.writeAsBytesSync(latest);
    pictures.workspace.write('chart.png', latest);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await _decode(tester, root: preview);
    _expectPixels(tester, preview, 9, 5);
    expect(snapshot.readAsBytesSync(), tinyPng);
    expect(pictures.workspace.watching('chart.png'), 1);
    expect(tester.takeException(), isNull);
  });
}
