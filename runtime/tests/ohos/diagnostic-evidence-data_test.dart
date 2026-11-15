import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/diagnostics/automatic_diagnostics.dart';
import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/diagnostics/diagnostics_sections.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

DiagnosticsSnapshot snapshot(NativeDiagnostics native) => DiagnosticsSnapshot(
  at: DateTime(2026, 11, 15),
  status: const RuntimeStatus(phase: RuntimePhase.running),
  settings: const AppSettings(),
  native: native,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final input = Platform.environment['OHOS_DIAGNOSTIC_EVIDENCE_WIRE'];
  if (input == null) throw StateError('OHOS_DIAGNOSTIC_EVIDENCE_WIRE must name actual ETS output');
  final wire = jsonDecode(File(input).readAsStringSync()) as Map<String, dynamic>;

  test('real MethodChannel consumer accepts actual OH evidence and retains existing record names', () async {
    const method = MethodChannel('dsh/diagnostics');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      return call.method == 'info' ? wire : null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(method, null),
    );
    const channel = DiagnosticsChannel(method);
    final native = await channel.info();
    expect((native.evidence['processExits'] as List).first, {
      'at': 100,
      'source': 'hiAppEvent',
      'event': 'APP_CRASH',
      'crashType': 'NativeCrash',
    });
    expect((native.evidence['processExits'] as List).last, {'at': 200, 'source': 'hiAppEvent', 'event': 'APP_FREEZE'});
    expect((native.evidence['availability'] as Map)['processExits'], 'available');
    await channel.recordAppError(source: 'flutter', errorType: 'StateError', stack: 'package:dsh_app/main.dart:12:4');
    await channel.recordVoiceStage('failed', backend: 'system', code: 7);
    expect(calls.map((call) => call.method), ['info', 'recordAppError', 'recordVoiceStage']);
    expect(calls.last.arguments, {'stage': 'failed', 'backend': 'system', 'code': 7});
  });

  test('OH event allowlist drops arbitrary content and never fabricates Android reason codes', () {
    final facts = diagnosticEvidenceFacts({
      'processExits': [
        {
          'at': 1,
          'source': 'hiAppEvent',
          'event': 'APP_CRASH',
          'crashType': 'JsError',
          'reason': 4,
          'exception': 'synthetic body',
          'logs': ['/private/path'],
          'status': 9,
        },
        {'at': 2, 'source': 'hiAppEvent', 'event': 'APP_FREEZE', 'crashType': 'synthetic body'},
        {'at': 3, 'source': 'hiAppEvent', 'event': 'private event', 'reason': 4},
      ],
    });
    expect(facts['processExits'], [
      {'at': 1, 'source': 'hiAppEvent', 'event': 'APP_CRASH', 'crashType': 'JsError'},
      {'at': 2, 'source': 'hiAppEvent', 'event': 'APP_FREEZE'},
    ]);
    expect(jsonEncode(facts), isNot(contains('synthetic')));
    expect(jsonEncode(facts), isNot(contains('private')));
    expect(diagnosticFailureWatermarks(facts), {'processExits': 2});
  });

  test('Android exit metadata and legacy failure decisions remain byte-for-byte equivalent', () {
    final rows = [
      {'at': 1, 'reason': 4, 'status': 0, 'importance': 100, 'pssKb': 20, 'rssKb': 30},
      {'at': 2, 'reason': 10, 'status': 0},
    ];
    final facts = diagnosticEvidenceFacts({'processExits': rows});
    expect(jsonEncode(facts['processExits']), jsonEncode(rows));
    expect(diagnosticFailureWatermarks(facts), {'processExits': 1});
    expect(
      diagnosticFailureWatermarks({
        'processExits': [
          {'at': 3, 'source': 'hiAppEvent', 'event': 'private event', 'reason': 4},
        ],
      }),
      isEmpty,
    );
  });

  test('OH crash categories have distinct bounded signatures and repeat timestamps do not change them', () {
    Set<String> keys(String event, String? crashType, int at) => diagnosticFailureFingerprints(
      snapshot(
        NativeDiagnostics(
          evidence: {
            'processExits': [
              {'at': at, 'source': 'hiAppEvent', 'event': event, if (crashType != null) 'crashType': crashType},
            ],
          },
        ),
      ),
      {},
    );
    final native = keys('APP_CRASH', 'NativeCrash', 1);
    final js = keys('APP_CRASH', 'JsError', 2);
    final freeze = keys('APP_FREEZE', null, 3);
    expect({...native, ...js, ...freeze}.length, 3);
    expect(keys('APP_CRASH', 'NativeCrash', 50), native);
  });

  test('automatic facts identify OH explicitly and sections keep failure observations content-free', () {
    final native = NativeDiagnostics.fromMap(wire), value = snapshot(native);
    final facts = diagnosticsAnalysisFacts(value), device = facts['device'] as Map;
    expect(device['platform'], 'ohos');
    expect(device['apiVersion'], 26);
    expect(device.containsKey('android'), isFalse);
    expect(device.containsKey('sdkInt'), isFalse);
    final encoded = jsonEncode(facts);
    expect(encoded, contains('APP_CRASH'));
    expect(encoded, contains('APP_FREEZE'));
    expect(encoded, isNot(contains('synthetic credential')));
    final sections = diagnosticsSections(value);
    expect(sections['evidence'], contains('hiAppEvent'));
    expect(utf8.encode(sections['evidence']!).length, lessThanOrEqualTo(diagnosticsSectionBytes));
  });

  test('OH system failures drive one analysis and durable watermarks prevent restart replay', () async {
    final native = NativeDiagnostics.fromMap(wire);
    final systemOnly = NativeDiagnostics(
      evidence: {'processExits': native.evidence['processExits'], 'appErrors': [], 'voiceStages': []},
    );
    var saved = <String, Object?>{};
    var sends = 0;
    AutomaticDiagnostics make() =>
        AutomaticDiagnostics(
          collect: () async => snapshot(systemOnly),
          load: () async => saved,
          store: (value) async {
            saved = jsonDecode(jsonEncode(value)) as Map<String, Object?>;
          },
        )..configure(Object(), (prompt, current, created) async {
          expect((saved['through'] as Map)['processExits'], 200);
          expect(prompt, contains('APP_CRASH'));
          expect(current(), isTrue);
          sends++;
        });
    final first = make();
    await first.check();
    expect(sends, 1);
    first.dispose();
    final second = make();
    await second.check();
    expect(sends, 1);
    second.dispose();
  });
}
