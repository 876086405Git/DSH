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
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';

const _channel = MethodChannel('dsh/companion_voice');
const _system = CompanionVoiceSettings(
  on: true,
  source: CompanionVoiceSource.system,
);
const _deepseek = CompanionVoiceSettings(
  on: true,
  source: CompanionVoiceSource.deepseek,
);
const _preset = CompanionVoiceSettings(
  on: true,
  source: CompanionVoiceSource.preset,
  preset: 'openai',
  presetKeys: {'openai': 'local-test-value-not-a-credential'},
);

class _LocalHttp extends HttpOverrides {}

// No global override: use the SDK's real HttpClient only for this exact local
// listener. A preset uses a separate explicit MockClient and never leaves host.
class _LoopbackClient extends http.BaseClient {
  _LoopbackClient(this.origin)
    : inner = IOClient(
        _LocalHttp().createHttpClient(null)..findProxy = (_) => 'DIRECT',
      );
  final String origin;
  final http.Client inner;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.origin != origin)
      throw StateError('non-loopback request forbidden: ${request.url}');
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

class _Native {
  _Native(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final row = jsonDecode(line) as Map<String, dynamic>;
          if (row['event'] case final Map event) {
            onEvent?.call(event);
            return;
          }
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
  void Function(Map)? onEvent;
  int next = 0;
  static Future<_Native> start() async {
    final node = Platform.environment['NODE'];
    if (node == null)
      throw StateError('NODE must name the installed local tool');
    return _Native(
      await Process.start(node, [
        File('../runtime/tests/ohos/companion-external-rpc.mjs').absolute.path,
      ]),
    );
  }

  Future<Object?> request(String method, [Object? args]) {
    final id = ++next, done = Completer<Object?>();
    pending[id] = done;
    process.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'args': args}),
    );
    return done.future.timeout(const Duration(seconds: 10));
  }

  Future<Map> snapshot() async => await request('snapshot') as Map;
  Future<void> close() async {
    await request('close');
    await process.stdin.close();
    expect(
      await process.exitCode.timeout(const Duration(seconds: 10)),
      0,
      reason: errors.toString(),
    );
  }
}

class _Rig {
  _Rig(
    this.native,
    this.server,
    this.folder, {
    String platform = 'ohos',
    bool direct = false,
    this.preset = false,
    bool holdHttp = false,
  }) : httpGate = holdHttp ? Completer<void>() : null {
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      httpRequests.add({
        'method': request.method,
        'path': request.uri.path,
        'body': body,
      });
      await httpGate?.future;
      final bytes = request.uri.path == '/v1/tools/tts' ? pcm : wav;
      request.response.headers.contentType = ContentType.binary;
      request.response.add(bytes);
      await request.response.close();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          final row = <String, Object?>{
            'method': call.method,
            'arguments': call.arguments,
          };
          wire.add(row);
          final result = await native.request('voice', {
            'method': call.method,
            'arguments': call.arguments,
          }) as Map;
          row['nativeResult'] = result;
          if (call.method == 'speak' &&
              (call.arguments as Map?)?['id'] == heldId &&
              !computed.isCompleted) {
            expect(result, {'value': true});
            computed.complete();
            await delivery.future;
          }
          if (result['error'] case final String code)
            throw PlatformException(code: code);
          return result['value'];
        });
    native.onEvent = (event) {
      unawaited(
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              _channel.name,
              const StandardMethodCodec().encodeMethodCall(
                MethodCall('event', event),
              ),
              (_) {},
            ),
      );
    };
    container = ProviderContainer(
      overrides: [
        operatingSystemProvider.overrideWithValue(platform),
        companionVoiceClientProvider.overrideWithValue(client),
        companionVoiceFolderProvider.overrideWithValue(() async {
          folderCalls++;
          return folder;
        }),
        deepSeekSpeechProvider.overrideWithValue(() async {
          resolverCalls++;
          return DirectDeepSeekSpeech(
            'local-test-value-not-a-credential',
            base: origin,
            client: () => _LoopbackClient(origin),
          );
        }),
      ],
    );
    _direct = direct;
    speaker = direct
        ? CompanionSpeaker(
            container.read(companionVoiceProvider),
            client,
            () async {
              folderCalls++;
              return folder;
            },
            container.read(deepSeekSpeechProvider),
          )
        : container.read(companionSpeakerProvider);
    sub = speaker.events.listen(events.add);
  }

  static final pcm = Uint8List.fromList(
    List<int>.generate(960, (i) => i.isEven ? 7 : 0),
  );
  static final wav = deepSeekWav(pcm);
  static Future<_Rig> start({
    String platform = 'ohos',
    bool direct = false,
    bool preset = false,
    bool holdHttp = false,
  }) async => _Rig(
    await _Native.start(),
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    await Directory.systemTemp.createTemp('dsh-companion-preflight-'),
    platform: platform,
    direct: direct,
    preset: preset,
    holdHttp: holdHttp,
  );
  final _Native native;
  final HttpServer server;
  final Directory folder;
  final bool preset;
  final Completer<void>? httpGate;
  final computed = Completer<void>(), delivery = Completer<void>();
  final httpRequests = <Map<String, Object?>>[],
      wire = <Map<String, Object?>>[];
  final events = <CompanionVoiceEvent>[];
  late final ProviderContainer container;
  late final CompanionSpeaker speaker;
  late final StreamSubscription<CompanionVoiceEvent> sub;
  late final bool _direct;
  String? heldId;
  int clientCreations = 0,
      folderCalls = 0,
      resolverCalls = 0,
      presetRequests = 0;
  String get origin => 'http://127.0.0.1:${server.port}';
  CompanionVoiceSettings get custom => CompanionVoiceSettings(
    on: true,
    source: CompanionVoiceSource.custom,
    customUrl: '$origin/speech',
    customBody: '{"text":"{text}"}',
  );
  CompanionVoiceSettings get openai => CompanionVoiceSettings(
    on: true,
    source: CompanionVoiceSource.openai,
    openaiBase: '$origin/v1',
  );
  int get requests => httpRequests.length + presetRequests;
  http.Client client() {
    clientCreations++;
    if (preset)
      return MockClient((request) async {
        presetRequests++;
        expect(
          request.url.toString(),
          'https://api.openai.com/v1/audio/speech',
        );
        return http.Response.bytes(wav, 200);
      });
    return _LoopbackClient(origin);
  }

  List<String> get files =>
      folder.listSync().map((f) => f.path.split('/').last).toList();
  Future<void> sdk(String text, String kind) async =>
      native.request('sdk', {'text': text, 'kind': kind});
  Future<void> waitFor(bool Function() condition) async {
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(end))
        throw StateError('finite condition did not complete');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> accepted(String text) async => waitFor(
    () => wire.any(
      (r) =>
          r['method'] == 'speak' &&
          (r['arguments'] as Map)['text'] == text &&
          r['nativeResult'] != null,
    ),
  );
  Future<void> record(String name, Object? result) async {
    debugPrint(
      jsonEncode({
        'case': name,
        'provider': speaker.runtimeType.toString(),
        'result': result,
        'lastError': speaker.lastError,
        'httpRequests': httpRequests,
        'presetRequests': presetRequests,
        'resolverCalls': resolverCalls,
        'clientCreations': clientCreations,
        'folderCalls': folderCalls,
        'files': files,
        'wire': wire,
        'events': events.map((e) => {'type': e.type.name, 'id': e.id}).toList(),
        'native': await native.snapshot(),
      }),
    );
  }

  Future<void> close() async {
    if (!delivery.isCompleted) delivery.complete();
    if (httpGate != null && !httpGate!.isCompleted) httpGate!.complete();
    await native.request('release-create');
    native.onEvent = null;
    await sub.cancel();
    if (_direct) speaker.dispose();
    container.dispose();
    await pumpEventQueue();
    await native.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await server.close(force: true);
    await folder.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final source in ['custom', 'openai', 'preset', 'deepseek']) {
    test(
      'ordinary OH $source preview rejects before synthesis, file work and native play',
      () async {
        final rig = await _Rig.start(preset: source == 'preset');
        try {
          final settings = switch (source) {
            'custom' => rig.custom,
            'openai' => rig.openai,
            'preset' => _preset,
            _ => _deepseek,
          };
          final result = await rig.speaker.preview(settings, '明确选中的外部音色。');
          await rig.record('preview-$source', result);
          expect(
            rig.requests,
            0,
            reason: 'a known unavailable encoded player must be rejected before external synthesis',
          );
          expect(rig.clientCreations, 0);
          expect(rig.resolverCalls, 0);
          expect(rig.folderCalls, 0);
          expect(rig.files, isEmpty);
          expect(rig.wire.where((r) => r['method'] == 'play'), isEmpty);
          expect(result, 'unsupported voice format');
          expect(rig.speaker.lastError, 'unsupported voice format');
        } finally {
          await rig.close();
        }
      },
    );
  }

  test('ordinary OH unconfigured preview preserves not-set-up and does not start external work', () async {
    final rig = await _Rig.start();
    try {
      for (final settings in [
        const CompanionVoiceSettings(source: CompanionVoiceSource.preset),
        const CompanionVoiceSettings(source: CompanionVoiceSource.custom),
      ]) {
        expect(await rig.speaker.preview(settings, '尚未配置。'), 'not-set-up');
      }
      await rig.record('unconfigured', 'not-set-up');
      expect(rig.requests, 0);
      expect(rig.clientCreations, 0);
      expect(rig.folderCalls, 0);
    } finally {
      await rig.close();
    }
  });

  test('enabled system changed to external keeps per-id system fallback without synthesis', () async {
    final rig = await _Rig.start();
    try {
      expect(await rig.speaker.ready(_system), isTrue);
      expect(
        await rig.speaker.ready(rig.custom),
        isTrue,
        reason: 'ready retains its configuration contract',
      );
      rig.speaker
        ..speak('line-a', '第一句。')
        ..speak('line-b', '第二句。');
      await rig.accepted('第一句。');
      expect(
        rig.wire
            .where((r) => r['method'] == 'speak')
            .map((r) => (r['arguments'] as Map)['id']),
        ['line-a'],
      );
      await rig.sdk('第一句。', 'start');
      await rig.sdk('第一句。', 'done');
      await rig.accepted('第二句。');
      await rig.sdk('第二句。', 'start');
      await rig.sdk('第二句。', 'done');
      await rig.waitFor(
        () =>
            rig.events
                .where((e) => e.type == CompanionVoiceEventType.done)
                .length ==
            2,
      );
      await rig.record('ready-fallback-two-lines', null);
      expect(
        rig.events
            .where((e) => e.type == CompanionVoiceEventType.fallback)
            .map((e) => e.id),
        ['line-a', 'line-b'],
      );
      expect(
        rig.events
            .where((e) => e.type == CompanionVoiceEventType.done)
            .map((e) => e.id),
        ['line-a', 'line-b'],
      );
      expect(rig.requests, 0);
      expect(rig.clientCreations, 0);
      expect(rig.folderCalls, 0);
      expect(rig.wire.where((r) => r['method'] == 'play'), isEmpty);
      expect(rig.speaker.lastError, 'unsupported voice format');
    } finally {
      await rig.close();
    }
  });

  test('cold external first line waits for finite system warm-up without beginning synthesis', () async {
    final rig = await _Rig.start(holdHttp: true);
    try {
      await rig.native.request('gate-create');
      expect(await rig.speaker.ready(rig.custom), isTrue);
      rig.speaker.speak('first', '首次预热。');
      await pumpEventQueue();
      expect(
        rig.events.where((e) => e.type == CompanionVoiceEventType.error),
        isEmpty,
      );
      await rig.native.request('release-create');
      await rig.speaker.warmPhone();
      rig.httpGate!.complete();
      await rig.accepted('首次预热。');
      await rig.sdk('首次预热。', 'done');
      await rig.waitFor(
        () => rig.events.any(
          (e) => e.type == CompanionVoiceEventType.done && e.id == 'first',
        ),
      );
      await rig.record('cold-first-line', null);
      expect(
        rig.events
            .where((e) => e.type == CompanionVoiceEventType.fallback)
            .map((e) => e.id),
        ['first'],
      );
      expect(rig.requests, 0);
      expect(rig.folderCalls, 0);
    } finally {
      await rig.close();
    }
  });

  test('unavailable system fallback gives each external id an error without synthesis', () async {
    final rig = await _Rig.start();
    try {
      await rig.native.request('unavailable');
      expect(await rig.speaker.ready(rig.custom), isTrue);
      rig.speaker
        ..speak('missing-a', '不可用一。')
        ..speak('missing-b', '不可用二。');
      await rig.waitFor(
        () =>
            rig.events
                .where((e) => e.type == CompanionVoiceEventType.error)
                .length ==
            2,
      );
      await rig.record('unavailable-two-errors', null);
      expect(
        rig.events
            .where((e) => e.type == CompanionVoiceEventType.error)
            .map((e) => e.id),
        ['missing-a', 'missing-b'],
      );
      expect(rig.requests, 0);
      expect(rig.folderCalls, 0);
      expect(
        rig.wire.where((r) => r['method'] == 'play' || r['method'] == 'speak'),
        isEmpty,
      );
    } finally {
      await rig.close();
    }
  });

  test('stop during finite fallback warm-up cannot submit the cancelled external id', () async {
    final rig = await _Rig.start(holdHttp: true);
    try {
      await rig.native.request('gate-create');
      expect(await rig.speaker.ready(rig.custom), isTrue);
      rig.speaker.speak('cancelled', '取消的首句。');
      await pumpEventQueue();
      rig.speaker.stop();
      await pumpEventQueue();
      await rig.native.request('release-create');
      rig.httpGate!.complete();
      await rig.speaker.warmPhone();
      await pumpEventQueue();
      await rig.record('stop-warm-up', null);
      expect(
        rig.wire.where((r) => r['method'] == 'speak' || r['method'] == 'play'),
        isEmpty,
      );
      expect(rig.requests, 0);
      expect(rig.folderCalls, 0);
    } finally {
      await rig.close();
    }
  });

  test('flush during accepted fallback ACK retires held old ids and keeps the new id', () async {
    final rig = await _Rig.start();
    try {
      expect(await rig.speaker.ready(_system), isTrue);
      expect(await rig.speaker.ready(rig.custom), isTrue);
      rig.heldId = 'old-a';
      rig.speaker
        ..speak('old-a', '已接受旧句。')
        ..speak('old-b', '尚未开始旧句。');
      await rig.computed.future.timeout(const Duration(seconds: 10));
      rig.speaker.speak('new', '替换的新句。', flush: true);
      rig.delivery.complete();
      await rig.accepted('替换的新句。');
      await rig.sdk('替换的新句。', 'done');
      await rig.waitFor(
        () => rig.events.any(
          (e) => e.type == CompanionVoiceEventType.done && e.id == 'new',
        ),
      );
      await rig.record('flush-late-ack', null);
      expect(
        rig.wire
            .where((r) => r['method'] == 'speak')
            .map((r) => (r['arguments'] as Map)['id']),
        ['old-a', 'new'],
      );
      expect(
        rig.events
            .where((e) => e.type == CompanionVoiceEventType.fallback)
            .map((e) => e.id),
        ['old-a', 'new'],
      );
      expect(rig.requests, 0);
      expect(rig.folderCalls, 0);
    } finally {
      await rig.close();
    }
  });

  for (final direct in [false, true]) {
    test(
      '${direct ? "default/internal constructor" : "actual Android provider"} retains external fetching and native refusal',
      () async {
        final rig = await _Rig.start(platform: 'android', direct: direct);
        try {
          final result = await rig.speaker.preview(rig.custom, '保持原调用。');
          await rig.record(
            direct ? 'default-control' : 'android-control',
            result,
          );
          expect(rig.requests, 1);
          expect(rig.clientCreations, 1);
          expect(rig.folderCalls, 1);
          expect(rig.files, ['companion-voice-preview-1.wav']);
          expect(rig.wire.where((r) => r['method'] == 'play'), hasLength(1));
          expect(result, 'cannot play wav');
        } finally {
          await rig.close();
        }
      },
    );
  }
}
