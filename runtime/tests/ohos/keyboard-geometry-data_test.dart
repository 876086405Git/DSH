import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_markdown.dart';
import 'package:dsh_app/diagnostics/system_ime_diagnostics.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:dsh_app/diagnostics/system_ime_evidence.dart';
import 'package:flutter_test/flutter_test.dart';

final _at = DateTime.fromMillisecondsSinceEpoch(1794744000000, isUtc: true);
Map<String, Object?> _reply() => {
  'source': 'ohosWindowGeometry', 'ok': true, 'code': 'ok',
  'capturedAt': _at.millisecondsSinceEpoch,
  'events': [
    {'timestamp': _at.millisecondsSinceEpoch, 'event': 'willShow',
     'origin': 'ohosWindow', 'fromUser': null, 'reason': 'unknown',
     'geometry': <String, Object?>{'begin': [0, 2400, 1080, 0], 'end': [0, 1500, 1080, 900],
       'animated': true, 'curve': 2, 'durationMs': 250, 'curveParams': [0.2, 0, 0.2, 1]}},
  ],
};

class _Pending extends DiagnosticsChannel {
  final requests = <Completer<SystemImeEvidence>>[];
  int cancellations = 0;
  @override Future<SystemImeEvidence> collectSystemIme() { final c = Completer<SystemImeEvidence>(); requests.add(c); return c.future; }
  @override Future<void> cancelSystemIme() async { cancellations++; }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual data parser accepts own-window geometry as a distinct source', () {
    final evidence = SystemImeEvidence.fromNative(_reply(), now: _at);
    expect(evidence.code, 'ok', reason: 'OH_KEYBOARD_GEOMETRY_REJECTED');
    expect(evidence.toJson()['source'], 'ohosWindowGeometry');
    expect(evidence.events.single.toJson()['geometry'], (_reply()['events'] as List).single['geometry']);
  });
  test('OH provider transport failure keeps own-window provenance', () async {
    final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue('ohos')]);
    addTearDown(container.dispose);
    const native = MethodChannel('dsh/diagnostics');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, (_) async => throw MissingPluginException());
    addTearDown(() => messenger.setMockMethodCallHandler(native, null));
    final evidence = await container.read(diagnosticsChannelProvider).collectSystemIme();
    expect(evidence.code, 'unsupported');
    expect(evidence.toJson()['source'], 'ohosWindowGeometry', reason: 'OH_FAILURE_MISLABELLED_PRIVILEGED');
  });

  test('actual ETS wire is consumed with all three geometry kinds', () {
    final path = Platform.environment['OHOS_KEYBOARD_CONSUMER_INPUT'];
    expect(path, isNotNull, reason: 'Native keyboard gate must provide its real codec receipt');
    final wire = jsonDecode(File(path!).readAsStringSync()) as Map;
    final value = SystemImeEvidence.fromNative(wire['reply'], now: DateTime.fromMillisecondsSinceEpoch(wire['now'] as int));
    expect(value.code, 'ok');
    expect(value.events.map((e) => e.event), ['willShow', 'height', 'avoidArea']);
    expect(value.events.last.geometry!['bottom'], [0, 1500, 1080, 900]);
  });

  test('fixed fields detach nested data and omit all text from JSON and markdown', () {
    final raw = _reply()..['rawLog'] = 'PRIVATE';
    final event = (raw['events'] as List).single as Map;
    final geometry = event['geometry'] as Map;
    event['text'] = 'PRIVATE'; geometry['input'] = 'PRIVATE';
    final value = SystemImeEvidence.fromNative(raw, now: _at);
    (geometry['end'] as List)[3] = 1;
    (geometry['curveParams'] as List)[0] = 99;
    expect(value.events.single.geometry!['end'], [0, 1500, 1080, 900]);
    expect(value.events.single.geometry!['curveParams'], [0.2, 0, 0.2, 1]);
    expect(() => (value.events.single.geometry!['end'] as List).clear(), throwsUnsupportedError);
    expect(() => value.events.single.geometry!.clear(), throwsUnsupportedError);
    final snapshot = DiagnosticsSnapshot(at: _at, status: const RuntimeStatus(phase: RuntimePhase.running), settings: const AppSettings(), systemIme: value);
    final md = diagnosticsMarkdown(snapshot);
    expect(md, contains('本应用键盘几何')); expect(md, contains('回调收到时间'));
    expect(md, isNot(contains('privilegedIme'))); expect(md, contains('900'));
    expect(jsonEncode(value.toJson()) + md, isNot(contains('PRIVATE')));
    final entry = DiagnosticsBundle.entries(snapshot).singleWhere((e) => e.name == 'system-ime.json');
    final exported = jsonDecode(utf8.decode(entry.bytes)) as Map;
    expect(exported['source'], 'ohosWindowGeometry');
    expect((exported['events'] as List).single['geometry']['end'], [0, 1500, 1080, 900]);
  });

  test('invalid dimensions, nonfinite numbers and text cannot become geometry', () {
    final invalid = <Map<String, Object?>>[
      {'begin': [0, 0, -1, 2]}, {'end': [0, 0, 1, -2]}, {'begin': [0, 1, 2]},
      {'end': [0, double.infinity, 1, 2]}, {'end': [0, 1, 'PRIVATE', 2]},
      {'animated': 'PRIVATE'}, {'curve': double.nan}, {'durationMs': -1}, {'durationMs': 3001},
      {'curveParams': [1, 2, 3, 4, 5]}, {'curveParams': ['PRIVATE']},
    ];
    for (final fields in invalid) {
      final raw = _reply(); ((raw['events'] as List).single['geometry'] as Map).addAll(fields);
      final value = SystemImeEvidence.fromNative(raw, now: _at);
      expect(value.code, 'failed', reason: fields.keys.join()); expect(value.source, 'ohosWindowGeometry');
      expect(value.events, isEmpty); expect(jsonEncode(value.toJson()), isNot(contains('PRIVATE')));
    }
  });

  test('OH events cannot masquerade as Android IME requests or user attribution', () {
    for (final fields in <Map<String, Object?>>[
      {'event': 'requestShow'}, {'origin': 'imeTracker'}, {'reason': 'SHOW_SOFT_INPUT'}, {'fromUser': false},
    ]) {
      final raw = _reply(); ((raw['events'] as List).single as Map).addAll(fields);
      expect(SystemImeEvidence.fromNative(raw, now: _at).code, 'failed');
    }
  });

  test('OH failures have no events and never imply normal keyboard operation', () {
    for (final code in SystemImeEvidence.codes.where((c) => c != 'ok')) {
      final raw = _reply()..['code'] = code..['ok'] = code == 'noEvents'..['events'] = [];
      final value = SystemImeEvidence.fromNative(raw, now: _at);
      expect(value.code, code); expect(value.source, 'ohosWindowGeometry'); expect(value.events, isEmpty);
      final snapshot = DiagnosticsSnapshot(at: _at, status: const RuntimeStatus(phase: RuntimePhase.running), settings: const AppSettings(), systemIme: value);
      expect(diagnosticsMarkdown(snapshot), contains('不能证明键盘行为正常'));
    }
  });

  test('OH limits mirror the native 64/120s bound and preserve arrival order at ties', () {
    final raw = _reply(); final template = (raw['events'] as List).single as Map;
    raw['events'] = List.generate(64, (i) => {...template, 'event': 'height', 'geometry': {'height': 63-i}});
    final value = SystemImeEvidence.fromNative(raw, now: _at);
    expect(value.events.map((e) => e.geometry!['height']), List.generate(64, (i) => 63-i));
    (raw['events'] as List).add(template); final limit = SystemImeEvidence.fromNative(raw, now: _at);
    expect(limit.code, 'limitExceeded'); expect(limit.source, 'ohosWindowGeometry');
    for (final delta in [-120001, 1]) {
      final one = _reply(); ((one['events'] as List).single as Map)['timestamp'] = _at.millisecondsSinceEpoch + delta;
      expect(SystemImeEvidence.fromNative(one, now: _at).code, 'failed');
    }
  });

  test('no collection on provider read; successful OH collection is explicit and has no arguments', () async {
    final calls = <MethodCall>[]; const native = MethodChannel('dsh/diagnostics');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, (call) async { calls.add(call); final reply = _reply(); final now = DateTime.now().millisecondsSinceEpoch; reply['capturedAt'] = now; ((reply['events'] as List).single as Map)['timestamp'] = now; return reply; });
    addTearDown(() => messenger.setMockMethodCallHandler(native, null));
    final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue('ohos')]); addTearDown(container.dispose);
    final channel = container.read(diagnosticsChannelProvider); expect(calls, isEmpty);
    expect((await channel.collectSystemIme()).code, 'ok'); expect(calls.single.method, 'collectSystemIme'); expect(calls.single.arguments, isNull);
  });

  test('coordinator cancellation discards old OH capture without clearing the new owner', () async {
    final channel = _Pending(); final state = SystemImeDiagnostics(channel); addTearDown(state.dispose);
    final first = state.collect(isCurrent: () => true); state.clear(); final second = state.collect(isCurrent: () => true);
    channel.requests[0].complete(SystemImeEvidence.fromNative(_reply(), now: _at)); await first;
    expect(state.collecting, isTrue); expect(state.evidence, isNull);
    channel.requests[1].complete(SystemImeEvidence.fromNative(_reply(), now: _at)); await second;
    expect(state.evidence?.source, 'ohosWindowGeometry'); expect(channel.cancellations, 1);
  });

}
