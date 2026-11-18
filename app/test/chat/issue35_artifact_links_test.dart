import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart' show testApp;

class _ImageReader implements WorkspaceImageReader {
  final calls = <(String, String)>[];

  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    calls.add((sessionId, path));
    throw const ArtifactError('missing');
  }
}

void main() {
  const cwd = '/root/workspace';
  final cases = <String, String>{
    'out/Q3%20report.docx': '$cwd/out/Q3 report.docx',
    '<out/Q3%20report.docx>': '$cwd/out/Q3 report.docx',
    'out/report%23v1.docx#page2': '$cwd/out/report#v1.docx',
    '<out/report%23v1.docx#page2>': '$cwd/out/report#v1.docx',
    'out/report%3Fv1.docx?download=1': '$cwd/out/report?v1.docx',
    'out/100%25.docx': '$cwd/out/100%.docx',
    'out/a%2520b.docx': '$cwd/out/a%20b.docx',
    '<out/a%2520b.docx>': '$cwd/out/a%20b.docx',
    'file:///root/report%23v1.docx': '/root/report#v1.docx',
    'file://localhost/root/a%20b.docx': '/root/a b.docx',
    '<file://localhost/root/a%2520b.docx>': '/root/a%20b.docx',
    'out/%E6%96%87%E6%A1%A3.docx': '$cwd/out/文档.docx',
    '../report.docx': '/root/report.docx',
    '<out/word report.docx>': '$cwd/out/word report.docx',
    // A Windows Host (#1430): a click opens these as the artifact card does.
    'C:/A/probe.png': 'C:/A/probe.png',
    'C:/A/my%20shot.png': 'C:/A/my shot.png',
    'C:/A/report.pdf?download=1#page2': 'C:/A/report.pdf',
    '<C:/A/my%20shot.png>': 'C:/A/my%20shot.png',
  };

  for (final MapEntry(key: target, value: expected) in cases.entries) {
    test('artifact and inline link resolve the same file: $target', () {
      expect(MarkdownBody.workspaceLinkPath(target, baseDir: cwd), expected);
      expect(linkedPaths('[document]($target)', cwd: cwd), [expected]);
    });
  }

  for (final target in [
    '#section',
    '?download=1',
    '//example.com/file.docx',
    'file://example.com/file.docx',
    'file://user@localhost/file.docx',
    'file://localhost:80/file.docx',
    'https://example.com/file.docx',
    'javascript:alert(1)',
    'file%3A%2F%2F%252Froot',
    'bad%FFname.docx',
  ]) {
    test('a nonlocal or invalid link does not become an artifact: $target', () {
      expect(MarkdownBody.workspaceLinkPath(target, baseDir: cwd), isNull);
      expect(linkedPaths('[document]($target)', cwd: cwd), isEmpty);
    });
  }

  test('links shown as examples in code are not artifacts (#1432)', () {
    const reply =
        '写好了 README：\n\n```markdown\n[截图](shot.png)\n```\n\n行内的 `[报告](out/report.pdf)` 也是示例，[真的](real.pdf) 才算。';
    expect(linkedPaths(reply, cwd: cwd), ['$cwd/real.pdf']);
    // Tildes inside a line are no fence.
    expect(linkedPaths('The marker ~~~ is literal. [real](real.pdf)', cwd: cwd), ['$cwd/real.pdf']);
    // A longer fence isn't closed by a shorter one inside it.
    expect(linkedPaths('~~~~md\n~~~\n[example](fake.pdf)\n~~~~\n[real](real.pdf)', cwd: cwd), ['$cwd/real.pdf']);
  });

  test('decoded paths deduplicate without decoding literal percent escapes twice', () {
    expect(linkedPaths('[one](out/a%20b.docx) [two](<out/a%20b.docx>)', cwd: cwd), ['$cwd/out/a b.docx']);
    expect(linkedPaths('[one](out/a%2520b.docx) [two](out/a%20b.docx)', cwd: cwd), [
      '$cwd/out/a%20b.docx',
      '$cwd/out/a b.docx',
    ]);
  });

  test('a workspace-relative cwd is retained consistently', () {
    expect(linkedPaths('[document](report.docx)', cwd: 'output'), ['output/report.docx']);
    expect(MarkdownBody.workspaceLinkPath('report.docx', baseDir: 'output'), 'output/report.docx');
  });

  test('existing Windows artifact paths keep their drive prefix', () {
    expect(linkedPaths(r'[document](C:\work\report.docx)', cwd: cwd), [r'C:\work\report.docx']);
    expect(linkedPaths('[document](C:/work/report.docx#L2)', cwd: cwd), ['C:/work/report.docx']);
  });

  test('workspace images use the same local URI rules', () {
    for (final MapEntry(key: target, value: expected) in cases.entries) {
      final source = imageSourceOf(target);
      expect(source, isA<WorkspaceImageSource>(), reason: target);
      expect(workspaceImagePath((source as WorkspaceImageSource).path, cwd: cwd), expected, reason: target);
    }
    for (final target in [
      '#section',
      '?download=1',
      '//example.com/chart.png',
      'file://example.com/chart.png',
      'file://user@localhost/chart.png',
      'file://localhost:80/chart.png',
      'file%3A%2F%2F%252Froot',
      'bad%FFname.png',
    ]) {
      expect(imageSourceOf(target), isA<UnsupportedImageSource>(), reason: target);
    }
  });

  test('web, data and Windows images keep their existing source channels', () {
    expect(
      (imageSourceOf('https://example.com/chart.png?size=2') as WebImageSource).url,
      'https://example.com/chart.png?size=2',
    );
    expect((imageSourceOf('HTTP://example.com/chart.png') as WebImageSource).url, 'HTTP://example.com/chart.png');
    expect((imageSourceOf('data:image/png;base64,AAAA') as DataImageSource).url, 'data:image/png;base64,AAAA');
    expect((imageSourceOf(r'C:\work\chart.png') as WorkspaceImageSource).path, r'C:\work\chart.png');
  });

  testWidgets('the real Markdown image reader receives one decoded local path', (tester) async {
    final reader = _ImageReader();
    await tester.pumpWidget(
      testApp(
        const MarkdownImageScope(
          sessionId: 's1',
          baseDir: cwd,
          child: Material(child: MarkdownBody(text: '![chart](file://localhost/root/chart%2520v1.png)')),
        ),
        overrides: [
          activeConnectionProvider.overrideWithValue(const AsyncData(null)),
          workspaceImageReaderProvider.overrideWithValue(CachedImageReader(reader)),
        ],
      ),
    );
    await tester.pump();
    expect(reader.calls, [('s1', '/root/chart%20v1.png')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a remote file authority never reaches the workspace image reader', (tester) async {
    final reader = _ImageReader();
    await tester.pumpWidget(
      testApp(
        const MarkdownImageScope(
          sessionId: 's1',
          baseDir: cwd,
          child: Material(child: MarkdownBody(text: '![chart](file://elsewhere/root/chart.png)')),
        ),
        overrides: [
          activeConnectionProvider.overrideWithValue(const AsyncData(null)),
          workspaceImageReaderProvider.overrideWithValue(CachedImageReader(reader)),
        ],
      ),
    );
    await tester.pump();
    expect(reader.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
