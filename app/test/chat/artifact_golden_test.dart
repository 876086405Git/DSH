// Goldens for the artifact cards: a turn's deliverables (collapsed past
// four, an image with its thumbnail), a turn's generated files, the 「文件」
// tab section of 对话详情, and the actions sheet.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/workspace_state.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/widgets/artifact_card.dart';
import 'package:dsh_app/ui/session/session_artifacts.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../files/support/memory_workspace.dart';
import 'support/harness.dart';

const _ws = '/root/workspace';

final _delivered = TurnArtifacts(
  turn: 1,
  endSeq: 12,
  files: const [
    Artifact(
      path: '$_ws/out/2026Q3-销售报告.pdf',
      origin: ArtifactOrigin.delivered,
      turn: 1,
      description: '2026 Q3 销售汇总,含分区域明细',
    ),
    Artifact(path: '$_ws/out/trend.png', origin: ArtifactOrigin.delivered, turn: 1),
    Artifact(
      path: '$_ws/out/sales-by-region.xlsx',
      origin: ArtifactOrigin.delivered,
      turn: 1,
      description: '原始数据(3 个工作表)',
    ),
    Artifact(path: '$_ws/out/review-deck.pptx', origin: ArtifactOrigin.delivered, turn: 1),
    Artifact(path: '$_ws/out/attachments.zip', origin: ArtifactOrigin.delivered, turn: 1),
  ],
);

final _generated = TurnArtifacts(
  turn: 2,
  endSeq: 30,
  files: const [
    Artifact(path: '$_ws/site/index.html', origin: ArtifactOrigin.written, turn: 2),
    Artifact(path: '$phoneOutputDir/会议纪要.docx', origin: ArtifactOrigin.phoneOutput, turn: 2, bytes: 48230),
  ],
);

/// A small "trend chart" to stand in for a generated image.
Future<Uint8List> _chartPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = Size(160, 160);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF4F6FB));
  final bar = Paint()..color = const Color(0xFF4D6BFE);
  const heights = <double>[40, 64, 52, 90, 118, 102, 136];
  for (final (i, h) in heights.indexed) {
    canvas.drawRect(Rect.fromLTWH(12 + i * 20.0, 150 - h, 14, h), bar);
  }
  final image = await recorder.endRecording().toImage(160, 160);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// `workspaceFiles/read` answered from memory.
MemoryWorkspace _files() => MemoryWorkspace(files: {'$phoneOutputDir/周会纪要.md': _notes});

const _notes = '''# 周会纪要

**时间**:10 月 24 日 14:00  
**参会**:产品、研发、运营

## 结论

1. Q3 报表按区域拆分,下周一前发出
2. 移动端改版延到 11 月,先修登录问题
3. 运营活动预算追加 **15%**

## 待办

- [ ] 张三:整理分区域数据
- [x] 李四:登录重复提交的修复上线''';

/// A rendered PDF page stand-in: a title bar and lines of "text".
Future<Uint8List> _pagePng(int width) async {
  final height = (width * 842 / 595).round();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = const Color(0xFFFFFFFF));
  final ink = Paint()..color = const Color(0xFF2B2F36);
  final grey = Paint()..color = const Color(0xFFB8BDC7);
  final w = width.toDouble();
  canvas.drawRect(Rect.fromLTWH(w * 0.1, w * 0.1, w * 0.5, w * 0.05), ink);
  for (var i = 0; i < 18; i++) {
    final y = w * 0.24 + i * w * 0.06;
    final len = i % 5 == 4 ? 0.45 : 0.8;
    canvas.drawRect(Rect.fromLTWH(w * 0.1, y, w * len, w * 0.022), grey);
  }
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  setUpAll(loadTestFonts);

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('artifact cards ($suffix)', (tester) async {
      usePhoneView(tester);
      tester.view.physicalSize = const Size(780, 2000);
      final png = (await tester.runAsync(_chartPng))!;
      final thumbnail = MemoryImage(png);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Builder(
              builder: (context) => AppBackdrop(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(0, 48, 0, 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ArtifactCard(sessionId: 's1', group: _delivered),
                            const SizedBox(height: 12),
                            ArtifactCard(sessionId: 's1', group: _generated),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      // 对话详情「文件」页签顶上的那一块(自带左右 16)。
                      const SessionArtifactsSection(sessionId: 's1'),
                    ],
                  ),
                ),
              ),
            ),
          ),
          brightness: brightness,
          overrides: [
            sessionArtifactsProvider('s1').overrideWithValue([_delivered, _generated]),
            activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection)),
            artifactThumbnailProvider.overrideWith((ref, key) async => key.$2.endsWith('.png') ? thumbnail : null),
            turnArtifactThumbnailProvider.overrideWith((ref, key) async => key.$2.endsWith('.png') ? thumbnail : null),
          ],
        ),
      );
      await tester.runAsync(() async {
        await precacheImage(ResizeImage(thumbnail, width: 80), tester.element(find.byType(ArtifactCard).first));
      });
      await pumpFrames(tester, 4);
      await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/artifacts_$suffix.png'));
    });

    testWidgets('artifact actions sheet ($suffix)', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: AppBackdrop(
              child: Center(
                child: Builder(
                  builder: (context) => FilledButton(
                    onPressed: () => showArtifactMenu(context, artifact: _delivered.files.first, canFetch: true),
                    child: const Text('菜单'),
                  ),
                ),
              ),
            ),
          ),
          brightness: brightness,
        ),
      );
      await tester.tap(find.text('菜单'));
      await pumpFrames(tester, 8);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/artifact_menu_$suffix.png'));
    });

    testWidgets('Markdown preview ($suffix)', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const ArtifactPreviewPage(
            sessionId: 's1',
            artifact: Artifact(path: '$phoneOutputDir/周会纪要.md', origin: ArtifactOrigin.phoneOutput, turn: 3),
          ),
          brightness: brightness,
          overrides: [workspaceSourceProvider('s1').overrideWithValue(_files())],
        ),
      );
      await pumpFrames(tester, 6);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/artifact_preview_$suffix.png'));
    });

    testWidgets('session artifacts page ($suffix)', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const SessionArtifactsPage(sessionId: 's1'),
          brightness: brightness,
          overrides: [
            sessionArtifactsProvider('s1').overrideWithValue([_delivered, _generated]),
            activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection)),
            artifactThumbnailProvider.overrideWith((ref, key) async => null),
            turnArtifactThumbnailProvider.overrideWith((ref, key) async => null),
          ],
        ),
      );
      await pumpFrames(tester, 6);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/session_artifacts_$suffix.png'));
    });

    testWidgets('PDF preview ($suffix)', (tester) async {
      usePhoneView(tester);
      final page = (await tester.runAsync(() => _pagePng(360)))!;
      const files = MethodChannel('dsh/files');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(files, (call) async {
        return switch (call.method) {
          'resolveGuest' => '/data/files/runtime/rootfs/root/workspace/r.pdf',
          'pdfInfo' => [
            for (var i = 0; i < 3; i++) {'width': 595, 'height': 842},
          ],
          'pdfPage' => page,
          _ => null,
        };
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(files, null));
      await tester.pumpWidget(
        testApp(
          ArtifactPreviewPage(sessionId: 's1', artifact: _delivered.files.first),
          brightness: brightness,
          overrides: [activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection))],
        ),
      );
      await pumpFrames(tester, 4);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await pumpFrames(tester, 4);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/artifact_pdf_$suffix.png'));
    });

    testWidgets('Office conversion wait ($suffix)', (tester) async {
      usePhoneView(tester);
      final remote = HostConnection(client: DshClient.withCarrier(_NeverCarrier()), label: '工作站', isLocal: false);
      await tester.pumpWidget(
        testApp(
          const ArtifactPreviewPage(
            sessionId: 's1',
            artifact: Artifact(path: '/home/me/out/review-deck.pptx', origin: ArtifactOrigin.delivered, turn: 1),
          ),
          brightness: brightness,
          overrides: [activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(remote))],
        ),
      );
      await pumpFrames(tester, 6);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/artifact_office_$suffix.png'));
    });
  }
}

/// A Host that never answers (a conversion still running).
class _NeverCarrier extends DshCarrier {
  @override
  String get kind => 'memory';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      Completer<RpcResult>().future;

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('no streams');

  @override
  Future<void> close() async {}
}
