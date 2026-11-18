import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_voice.dart';
import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

const _channel = MethodChannel('dsh/companion_voice');
const _system = CompanionVoiceSettings(source: CompanionVoiceSource.system);
const _deepseek = CompanionVoiceSettings(source: CompanionVoiceSource.deepseek);

class _Native {
  _Native(this.process) {
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final row = jsonDecode(line) as Map<String, dynamic>;
      final done = pending.remove(row['id']);
      if (row.containsKey('error')) {
        done?.completeError(StateError(row['error'] as String));
      } else {
        done?.complete(row['result']);
      }
    });
    process.stderr.transform(utf8.decoder).listen(errors.write);
  }
  final Process process;
  final pending = <int, Completer<Object?>>{};
  final errors = StringBuffer();
  int next = 0;

  static Future<_Native> start() async {
    final node = Platform.environment['NODE'];
    if (node == null) throw StateError('NODE must name the already installed local Node');
    return _Native(await Process.start(node, [
      File('../runtime/tests/ohos/system-tts-preview-rpc.mjs').absolute.path,
    ]));
  }

  Future<Object?> request(String method, [Object? args]) {
    final id = ++next, done = Completer<Object?>();
    pending[id] = done;
    process.stdin.writeln(jsonEncode({'id': id, 'method': method, 'args': args}));
    return done.future.timeout(const Duration(seconds: 10));
  }

  Future<Map> snapshot() async => await request('snapshot') as Map;

  Future<void> close() async {
    await request('close');
    await process.stdin.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0, reason: errors.toString());
  }
}

class _Rig {
  _Rig(this.native, {this.hold, String platform = 'ohos', bool defaultConstructor = false}) {
    container = ProviderContainer(overrides: [
      operatingSystemProvider.overrideWithValue(platform),
      deepSeekSpeechProvider.overrideWithValue(() async { resolverCalls++; return null; }),
      companionVoiceClientProvider.overrideWithValue(() => MockClient((_) async {
        httpRequests++;
        throw StateError('No external request is allowed');
      })),
    ]);
    speaker = defaultConstructor
        ? CompanionSpeaker(container.read(companionVoiceProvider), container.read(companionVoiceClientProvider),
            () async => Directory.systemTemp)
        : container.read(companionSpeakerProvider);
    _defaultConstructor = defaultConstructor;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      final row = <String, Object?>{'method': call.method, 'arguments': call.arguments};
      wire.add(row);
      final result = await native.request('voice', {'method': call.method, 'arguments': call.arguments}) as Map;
      row['nativeResult'] = result;
      if (call.method == hold && !_held) {
        _held = true;
        // The actual ETS has already computed true. Only delivery to Flutter
        // is held, never native initialization or acceptance after retirement.
        expect(result, {'value': true});
        computed.complete();
        await delivery.future;
      }
      if (result['error'] case final String code) throw PlatformException(code: code);
      return result['value'];
    });
  }
  final _Native native;
  final String? hold;
  final wire = <Map<String, Object?>>[];
  final computed = Completer<void>(), delivery = Completer<void>();
  late final ProviderContainer container;
  late final CompanionSpeaker speaker;
  bool _held = false, _disposed = false, _defaultConstructor = false;
  int resolverCalls = 0, httpRequests = 0;

  void disposeProvider() {
    if (_disposed) return;
    _disposed = true;
    if (_defaultConstructor) speaker.dispose();
    container.dispose();
  }

  Future<void> close() async {
    if (!delivery.isCompleted) delivery.complete();
    disposeProvider();
    await pumpEventQueue();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    await native.close();
  }

  void record(String name, Object? result, Map before, Map after) {
    debugPrint(jsonEncode({'case': name, 'provider': speaker.runtimeType.toString(), 'wire': wire,
      'before': before, 'after': after, 'oldResult': result, 'httpRequests': httpRequests,
      'resolverCalls': resolverCalls}));
  }
}

List<String> _texts(Map state) => [
  for (final engine in state['engines'] as List)
    for (final call in (engine as Map)['calls'] as List) (call as Map)['text'] as String,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('actual OH companion provider keeps a normal system preview and its original wire', () async {
    final rig = _Rig(await _Native.start());
    try {
      final result = await rig.speaker.preview(_system, '正常试听。');
      final state = await rig.native.snapshot();
      expect(result, isNull);
      expect(_texts(state), ['正常试听。']);
      expect(rig.wire.singleWhere((row) => row['method'] == 'speak')['arguments'],
        {'id': 'preview-1', 'text': '正常试听。', 'flush': true, 'pitch': 1.12, 'rate': 1.0});
      expect(rig.httpRequests, 0);
      rig.record('normal-oh', result, state, state);
    } finally { await rig.close(); }
  });

  for (final action in ['stop', 'replace-system', 'replace-deepseek', 'dispose']) {
    test('actual OH companion $action retires a preview whose ready delivery is pending', () async {
      final rig = _Rig(await _Native.start(), hold: 'ready');
      try {
        final old = rig.speaker.preview(_system, '旧系统试听。');
        await rig.computed.future.timeout(const Duration(seconds: 10));
        final before = await rig.native.snapshot();
        if (action == 'stop') rig.speaker.stop();
        if (action == 'dispose') rig.disposeProvider();
        if (action == 'replace-system') expect(await rig.speaker.preview(_system, '新系统试听。'), isNull);
        if (action == 'replace-deepseek') {
          expect(await rig.speaker.preview(_deepseek, '新的外部音色试听。'), 'unsupported voice format');
        }
        await pumpEventQueue();
        final stopCount = rig.wire.where((row) => row['method'] == 'stop').length;
        rig.delivery.complete();
        final result = await old.timeout(const Duration(seconds: 10));
        final after = await rig.native.snapshot();
        rig.record(action, result, before, after);
        expect(_texts(after), action == 'replace-system' ? ['新系统试听。'] : <String>[],
          reason: 'retired ready continuation must not submit old SDK speak');
        expect(result, 'cancelled');
        expect(rig.wire.where((row) => row['method'] == 'stop').length, stopCount,
          reason: 'old continuation must not globally stop a replacement owner');
        expect(rig.httpRequests, 0);
        if (action == 'replace-system') expect((after['engines'] as List).last['closed'], isFalse);
      } finally { await rig.close(); }
    });
  }

  test('OH replacement keeps a retired accepted preview from reporting success after its late speak ACK', () async {
    final rig = _Rig(await _Native.start(), hold: 'speak');
    try {
      final old = rig.speaker.preview(_system, '旧句已被接受。');
      await rig.computed.future.timeout(const Duration(seconds: 10));
      final before = await rig.native.snapshot();
      expect(_texts(before), ['旧句已被接受。']);
      expect(await rig.speaker.preview(_system, '新试听保持播放。'), isNull);
      final stopCount = rig.wire.where((row) => row['method'] == 'stop').length;
      rig.delivery.complete();
      final result = await old.timeout(const Duration(seconds: 10));
      final after = await rig.native.snapshot();
      rig.record('late-speak-ack', result, before, after);
      expect(_texts(after), ['旧句已被接受。', '新试听保持播放。']);
      expect((after['engines'] as List).last['closed'], isFalse);
      expect(rig.wire.where((row) => row['method'] == 'stop').length, stopCount);
      expect(result, 'cancelled', reason: 'retired old acceptance must not report null success to the settings producer');
    } finally { await rig.close(); }
  });

  for (final defaultConstructor in [false, true]) {
    test('${defaultConstructor ? "default constructor" : "actual Android companion provider"} preserves its original late-ready fallback and wire', () async {
      final rig = _Rig(await _Native.start(), hold: 'ready', platform: 'android', defaultConstructor: defaultConstructor);
      try {
        final old = rig.speaker.preview(_system, '原默认行为。');
        await rig.computed.future.timeout(const Duration(seconds: 10));
        final before = await rig.native.snapshot();
        rig.speaker.stop();
        await pumpEventQueue();
        rig.delivery.complete();
        final result = await old.timeout(const Duration(seconds: 10));
        final after = await rig.native.snapshot();
        rig.record(defaultConstructor ? 'default' : 'android', result, before, after);
        expect(result, isNull);
        expect(_texts(after), ['原默认行为。']);
        expect(rig.wire.singleWhere((row) => row['method'] == 'speak')['arguments'],
          {'id': 'preview-1', 'text': '原默认行为。', 'flush': true, 'pitch': 1.12, 'rate': 1.0});
      } finally { await rig.close(); }
    });
  }

  test('OH unavailable system service keeps its existing refusal without speaking or external work', () async {
    final rig = _Rig(await _Native.start());
    try {
      await rig.native.request('unavailable');
      expect(await rig.speaker.preview(_system, '服务不可用。'), 'no-phone-voice');
      expect(_texts(await rig.native.snapshot()), isEmpty);
      expect(rig.httpRequests, 0);
      expect(rig.resolverCalls, 0);
    } finally { await rig.close(); }
  });
}
