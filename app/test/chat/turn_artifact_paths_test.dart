import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_app/ui/chat/widgets/artifact_card.dart';
import 'package:dsh_app/ui/chat/widgets/tool_images.dart';
import 'package:dsh_app/ui/session/session_artifacts.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _path = '/ws/chart.png';
const _groups = [
  TurnArtifacts(
    turn: 1,
    endSeq: 4,
    files: [Artifact(path: _path, origin: ArtifactOrigin.delivered, turn: 1)],
  ),
  TurnArtifacts(
    turn: 2,
    endSeq: 8,
    files: [Artifact(path: _path, origin: ArtifactOrigin.delivered, turn: 2)],
  ),
];

void main() {
  setUpAll(loadTestFonts);

  testWidgets('the per-turn files page uses snapshots while the latest-path section stays live', (tester) async {
    usePhoneView(tester);
    Widget app(Widget child) => testApp(
      child,
      overrides: [
        activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
        sessionArtifactsProvider('s1').overrideWithValue(_groups),
        artifactThumbnailProvider.overrideWith((ref, key) async => null),
        turnArtifactThumbnailProvider.overrideWith((ref, key) async => null),
      ],
    );
    await tester.pumpWidget(app(const SessionArtifactsPage(sessionId: 's1')));
    await tester.pumpAndSettle();
    final tiles = tester.widgetList<ArtifactTile>(find.byType(ArtifactTile)).toList();
    expect(tiles.map((tile) => tile.artifact.turn), [2, 1]);
    expect(tiles.every((tile) => tile.artifact.snapshotImage), isTrue);
    await tester.pumpWidget(app(const Scaffold(body: SessionArtifactsSection(sessionId: 's1'))));
    await tester.pumpAndSettle();
    final latest = tester.widget<ArtifactTile>(find.byType(ArtifactTile)).artifact;
    expect(latest.turn, 2);
    expect(latest.snapshotImage, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final raw in ['chart.png', _path]) {
    testWidgets('tool image $raw shares the Markdown absolute snapshot path and preview', (tester) async {
      usePhoneView(tester);
      final requested = <(String, String, int)>[];
      final view = ToolView.of(
        ToolChatItem(
          callId: 'read-chart',
          name: 'read_image',
          arguments: '{"file_path":"$raw"}',
          status: ToolStatus.succeeded,
        ),
      );
      expect(view.imagePath, raw);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: MarkdownImageScope(
              sessionId: 's1',
              baseDir: '/ws',
              turn: 1,
              child: ToolImages(view: view),
            ),
          ),
          overrides: [
            activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
            turnArtifactThumbnailProvider.overrideWith((ref, key) async {
              requested.add(key);
              return MemoryImage(tinyPng);
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(requested, [('s1', _path, 1)]);
      expect(workspaceImagePath(raw, baseDir: '/ws', local: false), _path);
      final image = find.byType(Image);
      await tester.runAsync(() => precacheImage(tester.widget<Image>(image).image, tester.element(image)));
      await tester.pumpAndSettle();
      await tester.tap(image);
      await tester.pumpAndSettle();
      final artifact = tester.widget<ArtifactPreviewPage>(find.byType(ArtifactPreviewPage)).artifact;
      expect(artifact.path, _path);
      expect(artifact.turn, 1);
      expect(artifact.snapshotImage, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
