import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/engine/engine_status.dart';
import 'package:dsh_app/ui/settings/diagnostics_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';

void main() {
  final cases = <String, Map<String, Object?>>{
    'saved direct but compatible process': {
      'phase': 'running',
      'directEngineEnabled': true,
      'currentExecutionMode': 'proot',
      'launchSelectedMode': 'proot',
      'launchSpawned': true,
      'directEngineFallbackReason': 'incompatibleFiles',
    },
    'failed before spawn': {
      'phase': 'error',
      'directEngineEnabled': true,
      'launchSelectedMode': 'direct',
      'launchSpawned': false,
      'launchFailureReason': 'startFailed',
    },
    'exited direct': {
      'phase': 'error',
      'directEngineEnabled': true,
      'launchSelectedMode': 'direct',
      'launchSpawned': true,
      'launchFailureReason': 'exit:1',
    },
    'successful fresh direct': {
      'phase': 'running',
      'directEngineEnabled': true,
      'directEngineActive': true,
      'currentExecutionMode': 'direct',
      'launchSelectedMode': 'direct',
      'launchSpawned': true,
    },
    'older native unknown': {'phase': 'running', 'directEngineEnabled': true},
  };
  for (final entry in cases.entries) {
    test('copy and bundle preserve native facts: ${entry.key}', () {
      final status = RuntimeStatus.fromMap(entry.value);
      final copy =
          DiagnosticsPage.report(
                runtime: LocalRuntimeState(status: status, loaded: true),
                settings: const AppSettings(),
                connection: 'fixture',
                logLines: 0,
              )['runtime']
              as Map;
      final bundle =
          DiagnosticsBundle.summary(
                DiagnosticsSnapshot(at: DateTime.utc(2026), status: status, settings: const AppSettings()),
              )['runtime']
              as Map;
      for (final key in status.launchDiagnostics.keys) {
        expect(copy.containsKey(key), isTrue);
        expect(bundle.containsKey(key), isTrue);
        expect(copy[key], status.launchDiagnostics[key]);
        expect(bundle[key], copy[key]);
      }
      expect(copy['currentExecutionMode'], entry.value['currentExecutionMode']);
      expect(copy['launchFailureReason'], entry.value['launchFailureReason']);
    });
    testWidgets('visible actual facts ignore preference: ${entry.key}', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: AppLocale.zhCN,
          supportedLocales: AppLocale.supported,
          localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
          home: Scaffold(body: RuntimeLaunchFacts(status: RuntimeStatus.fromMap(entry.value))),
        ),
      );
      final l10n = lookupL10n(AppLocale.zhCN);
      final expected = switch (entry.value['currentExecutionMode']) {
        'direct' => l10n.phoneLaunchDirect,
        'proot' => l10n.phoneLaunchCompatible,
        _ => l10n.phoneLaunchNotObserved,
      };
      final actualRow = tester.widget<InfoRow>(
        find.byWidgetPredicate((widget) => widget is InfoRow && widget.label == l10n.phoneActualLaunchMode),
      );
      expect(actualRow.value, expected);
      expect(find.descendant(of: find.byWidget(actualRow), matching: find.text(expected)), findsOneWidget);
      if (entry.value['launchFailureReason'] case final String failure) {
        final text = failure == 'startFailed'
            ? l10n.phoneLaunchStartFailed
            : l10n.phoneLaunchExited(failure.substring(5));
        expect(find.text(text), findsOneWidget);
        expect(find.text(failure), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a failed Direct launch shows as the fallback reason, in words', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: AppLocale.zhCN,
        supportedLocales: AppLocale.supported,
        localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
        home: Scaffold(
          body: RuntimeLaunchFacts(
            status: RuntimeStatus.fromMap(const {
              'phase': 'running',
              'currentExecutionMode': 'proot',
              'launchSelectedMode': 'proot',
              'launchSpawned': true,
              'directEngineFallbackReason': 'directFailed',
            }),
          ),
        ),
      ),
    );
    final l10n = lookupL10n(AppLocale.zhCN);
    final row = tester.widget<InfoRow>(
      find.byWidgetPredicate((widget) => widget is InfoRow && widget.label == l10n.phoneDirectRejectedReason),
    );
    expect(row.value, l10n.phoneDirectLaunchFailed);
    expect(find.text('directFailed'), findsNothing);
  });

  for (final locale in [AppLocale.zhCN, AppLocale.en]) {
    testWidgets('fake-hard-link tidy reasons are said in words (${locale.languageCode})', (tester) async {
      final l10n = lookupL10n(locale);
      final words = {
        'incompatibleFiles': l10n.phoneDirectIncompatibleFiles,
        'notEnoughSpace': l10n.phoneDirectNotEnoughSpace,
        'migrationFailed': l10n.phoneDirectMigrationFailed,
      };
      for (final MapEntry(key: reason, value: text) in words.entries) {
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppLocale.supported,
            localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
            home: Scaffold(
              body: RuntimeLaunchFacts(
                status: RuntimeStatus.fromMap({
                  'phase': 'running',
                  'currentExecutionMode': 'proot',
                  'launchSelectedMode': 'proot',
                  'launchSpawned': true,
                  'directEngineFallbackReason': reason,
                }),
              ),
            ),
          ),
        );
        final row = tester.widget<InfoRow>(
          find.byWidgetPredicate((widget) => widget is InfoRow && widget.label == l10n.phoneDirectRejectedReason),
        );
        expect(row.value, text);
        expect(find.text(reason), findsNothing);
      }
      expect(words.values.toSet(), hasLength(3));
    });
  }

  test('the start says when it is tidying plugin files, and only then', () {
    final tidying = RuntimeStatus.fromMap(const {'phase': 'starting', 'tidyingFiles': true});
    expect(tidying.tidyingFiles, isTrue);
    expect(RuntimeStatus.fromMap(const {'phase': 'starting'}).tidyingFiles, isFalse);
    final l10n = lookupL10n(AppLocale.zhCN);
    expect(EngineStatusView.of(LocalRuntimeState(status: tidying, loaded: true)).label, l10n.phoneEngineTidyingFiles);
    expect(engineDetail(tidying), l10n.phoneEngineTidyingFilesEllipsis);
    final plain = RuntimeStatus.fromMap(const {'phase': 'starting'});
    expect(EngineStatusView.of(LocalRuntimeState(status: plain, loaded: true)).label, l10n.phoneEngineStarting);
    expect(engineDetail(plain), l10n.phoneEngineStartingEllipsis);
  });

  testWidgets('launch rows line up with the card\'s other rows, 2dp apart', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final status = RuntimeStatus.fromMap(cases['exited direct']!);
    await tester.pumpWidget(
      MaterialApp(
        theme: withTestFonts(buildLightTheme()),
        locale: AppLocale.zhCN,
        supportedLocales: AppLocale.supported,
        localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
        home: Scaffold(
          body: SettingsSection(
            children: [
              const InfoRow(label: '架构', value: 'arm64-v8a'),
              RuntimeLaunchFacts(status: status),
              const InfoRow(label: 'DSH', value: '0.2.0'),
            ],
          ),
        ),
      ),
    );
    final l10n = lookupL10n(AppLocale.zhCN);
    final rows = tester.widgetList<InfoRow>(find.byType(InfoRow)).toList();
    expect(rows.map((row) => row.label), [
      '架构',
      l10n.phoneActualLaunchMode,
      l10n.phoneLastLaunchSelection,
      l10n.phoneLaunchFailureReason,
      'DSH',
    ]);
    final boxes = [for (final row in rows) tester.getRect(find.byWidget(row))];
    final labels = [for (final row in rows) tester.getRect(find.text(row.label))];
    final values = [for (final row in rows) tester.getRect(find.text(row.value))];
    for (var i = 1; i < rows.length; i++) {
      expect(boxes[i].left, boxes[0].left);
      expect(boxes[i].right, boxes[0].right);
      expect(labels[i].left, labels[0].left);
      expect(values[i].right, closeTo(values[0].right, 0.01));
      expect(boxes[i].top - boxes[i - 1].bottom, 2);
    }
  });

  testWidgets('HarmonyOS\'s launch reads in words, not its code names', (tester) async {
    final l10n = lookupL10n(AppLocale.zhCN);
    await tester.pumpWidget(
      MaterialApp(
        locale: AppLocale.zhCN,
        supportedLocales: AppLocale.supported,
        localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
        home: const Scaffold(
          body: RuntimeLaunchFacts(
            status: RuntimeStatus(
              phase: RuntimePhase.error,
              launchSelectedMode: 'ohos-embedded',
              launchFailureReason: 'ohos_node_exited',
            ),
          ),
        ),
      ),
    );
    expect(find.text(l10n.harmonyLaunchEmbedded), findsOneWidget);
    expect(find.text(l10n.harmonyLaunchNodeExited), findsOneWidget);
    expect(find.textContaining('ohos'), findsNothing);
  });
}
