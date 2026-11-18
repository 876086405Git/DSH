import 'dart:async';

import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/diagnostics/system_ime_diagnostics.dart';
import 'package:dsh_app/diagnostics/system_ime_evidence.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/settings/diagnostics_page.dart';
import 'package:dsh_app/state/android_features.dart' show operatingSystemProvider;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'support/system_ime_fixture.dart';

class _Channel extends DiagnosticsChannel {
  final requests = <Completer<SystemImeEvidence>>[];
  int cancellations = 0;

  @override
  Future<SystemImeEvidence> collectSystemIme() {
    final reply = Completer<SystemImeEvidence>();
    requests.add(reply);
    return reply.future;
  }

  @override
  Future<void> cancelSystemIme() async { cancellations++; }
}

Future<void> _pump(WidgetTester tester, SystemImeDiagnostics diagnostics, {String os = 'android'}) async {
  await tester.pumpWidget(goldenApp(
    home: const Scaffold(body: SingleChildScrollView(child: SystemImeDiagnosticsSection())),
    brightness: Brightness.light,
    overrides: [
      systemImeDiagnosticsProvider.overrideWithValue(diagnostics),
      operatingSystemProvider.overrideWithValue(os),
    ],
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('visiting never captures; explicit capture shows state/count and clear rejects late replies', (tester) async {
    final channel = _Channel();
    final diagnostics = SystemImeDiagnostics(channel);
    addTearDown(diagnostics.dispose);
    await _pump(tester, diagnostics);
    expect(channel.requests, isEmpty);
    expect(find.text(appL10n.systemImeNotCollected), findsOneWidget);
    expect(find.text('0 / 64'), findsOneWidget);
    await tester.tap(find.text(appL10n.systemImeCollect));
    await tester.pump();
    expect(channel.requests, hasLength(1));
    expect(find.text(appL10n.systemImeCollecting), findsOneWidget);
    await tester.ensureVisible(find.text(appL10n.systemImeClear));
    await tester.tap(find.text(appL10n.systemImeClear));
    await tester.pump();
    expect(channel.cancellations, greaterThanOrEqualTo(1));
    channel.requests.single.complete(systemImeEvidence());
    await tester.pump();
    expect(diagnostics.evidence, isNull);
    expect(find.text(appL10n.systemImeNotCollected), findsOneWidget);
  });

  testWidgets('pushing another route cancels pending but retains already completed evidence', (tester) async {
    final channel = _Channel();
    final diagnostics = SystemImeDiagnostics(channel);
    addTearDown(diagnostics.dispose);
    await _pump(tester, diagnostics);
    final navigator = Navigator.of(tester.element(find.byType(SystemImeDiagnosticsSection)));
    await tester.tap(find.text(appL10n.systemImeCollect));
    await tester.pump();
    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('away')))));
    await tester.pumpAndSettle();
    expect(diagnostics.collecting, isFalse);
    expect(channel.cancellations, greaterThanOrEqualTo(1));
    channel.requests.single.complete(systemImeEvidence());
    await tester.pump();
    expect(diagnostics.evidence, isNull);
    navigator.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text(appL10n.systemImeCollect));
    channel.requests.last.complete(systemImeEvidence(count: 2));
    await tester.pump();
    expect(find.text('2 / 64'), findsOneWidget);
    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('away')))));
    await tester.pumpAndSettle();
    expect(diagnostics.evidence?.events, hasLength(2));
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text(appL10n.systemImeRetained), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(diagnostics.evidence?.events, hasLength(2), reason: 'page disposal is not evidence clearing');
  });

  testWidgets('native dialog inactivity preserves consent and its successful result', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    final channel = _Channel();
    final diagnostics = SystemImeDiagnostics(channel);
    addTearDown(diagnostics.dispose);
    await _pump(tester, diagnostics);
    await tester.tap(find.text(appL10n.systemImeCollect));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(diagnostics.collecting, isTrue);
    expect(channel.cancellations, 0);
    channel.requests.single.complete(systemImeEvidence());
    await tester.pump();
    expect(diagnostics.evidence?.events, hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text(appL10n.systemImeRetained), findsOneWidget);
  });

  for (final target in [AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.detached]) {
    testWidgets('actually leaving ($target) still cancels and discards late evidence', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final channel = _Channel();
      final diagnostics = SystemImeDiagnostics(channel);
      addTearDown(diagnostics.dispose);
      await _pump(tester, diagnostics);
      await tester.tap(find.text(appL10n.systemImeCollect));
      await tester.pump();
      for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.detached]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        if (state == target) break;
      }
      expect(diagnostics.collecting, isFalse);
      expect(channel.cancellations, greaterThanOrEqualTo(1));
      channel.requests.single.complete(systemImeEvidence());
      if (target == AppLifecycleState.paused) tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      if (target != AppLifecycleState.detached) tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(diagnostics.evidence, isNull);
    });
  }

  testWidgets('unavailable gives an optional settings entry without opening or requesting permissions', (tester) async {
    final channel = _Channel();
    final diagnostics = SystemImeDiagnostics(channel);
    addTearDown(diagnostics.dispose);
    await _pump(tester, diagnostics);
    expect(find.text(appL10n.systemImePermissions), findsNothing);
    await tester.tap(find.text(appL10n.systemImeCollect));
    channel.requests.single.complete(systemImeEvidence(code: 'unavailable', count: 0));
    await tester.pump();
    expect(find.text(appL10n.systemImeUnavailable), findsOneWidget);
    expect(find.text(appL10n.systemImePermissions), findsOneWidget);
    expect(find.text(appL10n.systemImePermissionsHint), findsOneWidget);
    expect(find.text(appL10n.systemImeEvidenceLimits), findsOneWidget);
    expect(channel.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('on HarmonyOS it is this app\'s keyboard geometry, and unavailable sends nowhere', (tester) async {
    final channel = _Channel();
    final diagnostics = SystemImeDiagnostics(channel);
    addTearDown(diagnostics.dispose);
    await _pump(tester, diagnostics, os: 'ohos');
    expect(find.text(appL10n.systemImeOhosTitle), findsOneWidget);
    expect(find.text(appL10n.systemImeTitle), findsNothing);
    expect(find.text(appL10n.systemImeOhosPrivacy), findsOneWidget);
    await tester.tap(find.text(appL10n.systemImeOhosCollect));
    channel.requests.single.complete(systemImeEvidence(code: 'unavailable', count: 0));
    await tester.pump();
    expect(find.text(appL10n.systemImeOhosUnavailable), findsOneWidget);
    expect(find.text(appL10n.systemImePermissions), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
