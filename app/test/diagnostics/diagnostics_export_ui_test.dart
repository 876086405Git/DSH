// 「导出诊断包」 on screen: the step an export is on, the confirmation, errors
// in words, the sheet the failure card opens (it closes before its toast),
// measured symmetry, and goldens (light + dark). Regenerate the goldens with
// `flutter test --update-goldens test/diagnostics`.

import 'dart:async';

import 'package:dsh_app/diagnostics/diagnostics_export.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/engine/diagnostics_export_card.dart';
import 'package:dsh_app/ui/safe_mode/engine_failure_card.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safe_mode/support.dart' show FakeBridge, failedStatus, lkgUseful;
import '../shell/golden_harness.dart';

/// Walks through the steps on cue instead of touching files.
class _ScriptedExporter extends DiagnosticsExporter {
  _ScriptedExporter({this.failWith, this.savedAt})
    : super(collect: (_) => throw UnimplementedError(), files: const FilesChannel());

  final Object? failWith;
  final String? savedAt;
  final packed = Completer<void>();
  final done = Completer<void>();
  int shares = 0;

  Future<void> _walk(void Function(DiagnosticsStep step)? onStep, DiagnosticsStep last) async {
    onStep?.call(DiagnosticsStep.collecting);
    await packed.future;
    onStep?.call(DiagnosticsStep.packing);
    await done.future;
    if (failWith case final error?) throw error;
    onStep?.call(last);
  }

  @override
  Future<String> saveToDownloads({void Function(DiagnosticsStep step)? onStep}) async {
    await _walk(onStep, DiagnosticsStep.saving);
    return savedAt ?? 'Download/DSH-Go/dsh-go-diagnostics-20261024-153012.zip';
  }

  @override
  Future<bool> share({void Function(DiagnosticsStep step)? onStep}) async {
    await _walk(onStep, DiagnosticsStep.sharing);
    shares++;
    return true;
  }
}

/// A page with the card, and a button that opens the sheet.
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          const DiagnosticsExportCard(),
          const DiagnosticsBundleNote(),
          const Spacer(),
          Center(
            child: TextButton(
              onPressed: () => unawaited(showDiagnosticsExportSheet(context)),
              child: const Text('打开导出'),
            ),
          ),
          const SizedBox(height: 120),
        ],
      ),
    ),
  );
}

Future<_ScriptedExporter> _pump(WidgetTester tester, {Object? failWith, String? savedAt, String? os}) async {
  final exporter = _ScriptedExporter(failWith: failWith, savedAt: savedAt);
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: const _Host(),
      brightness: Brightness.light,
      overrides: [
        if (os != null) operatingSystemProvider.overrideWithValue(os),
        diagnosticsExporterProvider.overrideWithValue(exporter),
      ],
    ),
  );
  await tester.pump();
  return exporter;
}

Finder _row(String title) => find.ancestor(of: find.text(title), matching: find.byType(ListPageRow)).first;

void main() {
  testWidgets('saving shows each step, then where it went', (tester) async {
    final exporter = await _pump(tester);
    expect(find.text('存进 下载/DSH-Go'), findsOneWidget);

    await tester.tap(find.text('存到「下载」'));
    await tester.pump();
    expect(find.text('正在收集…'), findsOneWidget);
    expect(find.descendant(of: _row('存到「下载」'), matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    // The other way out waits.
    expect(tester.widget<ListPageRow>(_row('分享诊断包')).onTap, isNull);

    exporter.packed.complete();
    await tester.pump();
    expect(find.text('正在打包…'), findsOneWidget);

    exporter.done.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已存到 下载/DSH-Go/dsh-go-diagnostics-20261024-153012.zip'), findsOneWidget);
    expect(find.text('存进 下载/DSH-Go'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.widget<ListPageRow>(_row('分享诊断包')).onTap, isNotNull);
  });

  testWidgets('a refused save says why in words', (tester) async {
    final exporter = await _pump(tester, failWith: PlatformException(code: 'permission'));
    await tester.tap(find.text('存到「下载」'));
    await tester.pump();
    exporter.packed.complete();
    exporter.done.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('没有存储权限，存不进「下载」'), findsOneWidget);
    expect(find.text('存进 下载/DSH-Go'), findsOneWidget);
  });

  group('HarmonyOS, where the system asks where', () {
    const picked = 'file://docs/storage/Users/currentUser/Download/d.zip';

    test('the words, by OS and by what came back', () {
      expect(diagnosticsStepText(DiagnosticsStep.saving, harmony: true), '正在保存…');
      expect(diagnosticsStepText(DiagnosticsStep.saving, harmony: false), '正在存到「下载」…');
      expect(diagnosticsStepText(DiagnosticsStep.packing, harmony: true), '正在打包…');
      expect(diagnosticsSavedText(picked), '已保存');
      expect(diagnosticsSavedText('Download/DSH-Go/d.zip'), '已存到 下载/DSH-Go/d.zip');
    });

    testWidgets('asks where, and says 已保存 instead of the URI', (tester) async {
      final exporter = await _pump(tester, savedAt: picked, os: 'ohos');
      expect(find.text('选择保存位置'), findsOneWidget);
      expect(find.text('存到「下载」'), findsNothing);
      expect(find.text('存进 下载/DSH-Go'), findsNothing);
      await tester.tap(find.text('保存到文件'));
      await tester.pump();
      exporter.packed.complete();
      exporter.done.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('已保存'), findsOneWidget);
      expect(find.textContaining('file://'), findsNothing);
    });

    testWidgets('backing out of the window: no toast, the row back as it was', (tester) async {
      final exporter = await _pump(
        tester,
        failWith: PlatformException(code: 'cancelled'),
        os: 'ohos',
      );
      await tester.tap(find.text('保存到文件'));
      await tester.pump();
      exporter.packed.complete();
      exporter.done.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('已保存'), findsNothing);
      expect(find.text('选择保存位置'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('backing out from the sheet leaves it open', (tester) async {
      final exporter = await _pump(
        tester,
        failWith: PlatformException(code: 'cancelled'),
        os: 'ohos',
      );
      await tester.tap(find.text('打开导出'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('保存到文件').last);
      await tester.pump();
      exporter.packed.complete();
      exporter.done.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('导出诊断包'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a save that really failed still says so', (tester) async {
      final exporter = await _pump(
        tester,
        failWith: PlatformException(code: 'failed'),
        os: 'ohos',
      );
      await tester.tap(find.text('保存到文件'));
      await tester.pump();
      exporter.packed.complete();
      exporter.done.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('没能导出诊断包'), findsOneWidget);
    });
  });

  testWidgets('the sheet closes before it confirms a save', (tester) async {
    final exporter = await _pump(tester);
    await tester.tap(find.text('打开导出'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('导出诊断包'), findsOneWidget);
    final sheetRow = find.text('存到「下载」').last;
    await tester.tap(sheetRow);
    await tester.pump();
    exporter.packed.complete();
    exporter.done.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('导出诊断包'), findsNothing);
    expect(find.text('已存到 下载/DSH-Go/dsh-go-diagnostics-20261024-153012.zip'), findsOneWidget);
  });

  testWidgets('sharing from the sheet closes it once sent', (tester) async {
    final exporter = await _pump(tester);
    await tester.tap(find.text('打开导出'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('分享诊断包').last);
    await tester.pump();
    exporter.packed.complete();
    exporter.done.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(exporter.shares, 1);
    expect(find.text('导出诊断包'), findsNothing);
  });

  testWidgets('sheet geometry: the card on the 20 gutter, the note on its content column', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('打开导出'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final sheet = find.byType(BottomSheet);
    Finder inSheet(Finder f) => find.descendant(of: sheet, matching: f);
    final card = tester.getRect(
      find.descendant(of: inSheet(find.byType(ListPageCard)), matching: find.byType(GlassSurface)),
    );
    expect(card.left, 20);
    expect(card.right, 390 - 20);
    final note = tester.getRect(inSheet(find.byType(DiagnosticsBundleNote)));
    expect(note.left, 0);
    expect(note.right, 390);
    final noteText = tester.getRect(inSheet(find.text(diagnosticsBundleNote)));
    expect(noteText.left, 28);
    // The rows' icons share one column, 16 into the card.
    final share = tester.getRect(inSheet(find.byIcon(AppIcons.share)));
    final save = tester.getRect(inSheet(find.byIcon(AppIcons.download)));
    expect(share.center.dx, closeTo(save.center.dx, .5));
    expect(share.center.dx, closeTo(card.left + ListPageRow.horizontal + ListPageRow.glyphSlot / 2, .5));
  });

  testWidgets('the failure card offers 导出诊断包 next to 查看日志', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const Scaffold(
          body: SafeArea(
            child: Padding(padding: EdgeInsets.all(16), child: EngineFailureCard()),
          ),
        ),
        brightness: Brightness.light,
        overrides: [
          runtimeBridgeProvider.overrideWithValue(FakeBridge(lkg: lkgUseful)),
          localRuntimeProvider.overrideWith(() => FakeRuntime(LocalRuntimeState(loaded: true, status: failedStatus()))),
          diagnosticsExporterProvider.overrideWithValue(_ScriptedExporter()),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.widgetWithText(TextButton, '查看日志'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '导出诊断包'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(DiagnosticsExportCard), findsOneWidget);
    expect(find.text('存到「下载」'), findsOneWidget);
  });

  goldenBoth(
    'diagnostics_export_sheet',
    () => const _Host(),
    overrides: () => [diagnosticsExporterProvider.overrideWithValue(_ScriptedExporter())],
    before: (tester) async {
      await tester.tap(find.text('打开导出'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  // Mid-export: the step in the row's subtitle, a quiet ring for the chevron.
  goldenBoth(
    'diagnostics_export_busy',
    () => const _Host(),
    overrides: () => [diagnosticsExporterProvider.overrideWithValue(_ScriptedExporter()..packed.complete())],
    before: (tester) async {
      await tester.tap(find.text('存到「下载」'));
      await tester.pump();
      await tester.pump();
    },
  );
}
