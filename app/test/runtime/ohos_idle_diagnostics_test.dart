import 'package:dsh_app/runtime/ohos_idle_diagnostics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/runtime');
  const client = OhosIdleDiagnosticsChannel(channel);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('OH idle diagnostics keeps an unstarted window distinct from measured zero', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'schema': 1, 'enabled': false, 'observedAtMs': 1000, 'window': null};
    });
    final result = await client.read();
    expect(result.enabled, isFalse);
    expect(result.window, isNull);
    expect(result.observedAtMs, 1000);
    expect(calls.map((call) => call.method), ['getIdleDiagnostics']);
    expect(calls.single.arguments, isNull);
  });

  test('OH idle diagnostics sends explicit toggles and preserves window counts through the codec', () async {
    final calls = <MethodCall>[];
    final replies = [
      _wire(enabled: true, observedAt: 1001, collectCalls: 0),
      _wire(enabled: true, observedAt: 1020, collectCalls: 3),
      _wire(enabled: false, observedAt: 1025, collectCalls: 3, stoppedAt: 1025),
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return replies[calls.length - 1];
    });
    final started = await client.setEnabled(true);
    final observed = await client.read();
    final stopped = await client.setEnabled(false);
    expect(started.enabled, isTrue);
    expect(started.window!.counters['collectCalls'], 0);
    expect(observed.window!.counters['collectCalls'], 3);
    expect(observed.window!.counters.keys, OhosIdleDiagnosticsWindow.counterNames);
    expect(stopped.enabled, isFalse);
    expect(stopped.window!.id, started.window!.id);
    expect(stopped.window!.startedAtMs, 1000);
    expect(stopped.window!.stoppedAtMs, 1025);
    expect(stopped.window!.counters, observed.window!.counters);
    expect(() => stopped.window!.counters['collectCalls'] = 99, throwsUnsupportedError);
    expect(calls.map((call) => call.method), [
      'setIdleDiagnosticsEnabled',
      'getIdleDiagnostics',
      'setIdleDiagnosticsEnabled',
    ]);
    expect(calls[0].arguments, {'enabled': true});
    expect(calls[1].arguments, isNull);
    expect(calls[2].arguments, {'enabled': false});
  });

  test('OH idle diagnostics does not report unsupported native methods as zero work', () async {
    await expectLater(client.read(), throwsA(isA<MissingPluginException>()));
  });
}

Map<String, Object?> _wire({
  required bool enabled,
  required int observedAt,
  required int collectCalls,
  int? stoppedAt,
}) => {
  'schema': 1,
  'enabled': enabled,
  'observedAtMs': observedAt,
  'window': {
    'id': 'fixture-window-one',
    'startedAtMs': 1000,
    'stoppedAtMs': stoppedAt,
    'counters': {
      'pollTicks': 0,
      'collectCalls': collectCalls,
      'snapshotCalls': 0,
      'emitStatusCalls': 0,
      'lifecycleRefreshRequests': 0,
      'manifestPairChecks': 0,
    },
  },
};
