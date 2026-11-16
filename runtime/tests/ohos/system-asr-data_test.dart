// Real Flutter / production Dart data paths. Only the native channel boundary
// is substituted; these checks do not claim an SDK build or microphone result.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show Float32List;

import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/streaming_asr_state.dart';
import 'package:dsh_app/voice/live_words.dart';
import 'package:dsh_app/voice/native_trial.dart';
import 'package:dsh_app/voice/ohos_streaming_asr.dart';
import 'package:dsh_app/voice/streaming_asr.dart';
import 'package:dsh_app/voice/streaming_pcm.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../app/test/speech/speech_fakes.dart'
    show FakeCloud, FakeConversation, FakeOut;

const _asrChannel = MethodChannel('dsh/streaming_asr');
const _voiceChannel = MethodChannel('dsh/voice');
const _speechChannel = MethodChannel('dsh/speech');
const _model = StreamingAsrModel.system();

Future<void> _flush() => pumpEventQueue(times: 12);

Map<Object?, Object?> _args(MethodCall call) =>
    call.arguments as Map<Object?, Object?>;

class _ObservedAsr {
  final events = <StreamingAsrEvent>[];
  final errors = <Object>[];
}

// The existing Android isolate runs normally; only its unavailable native
// model/FFI decoder is replaced for the stream-error propagation regression.
class _IdleDecoder implements StreamingAsrDecoder {
  _IdleDecoder(StreamingAsrModel _);
  @override
  String get text => '';
  @override
  bool get isEndpoint => false;
  @override
  void feed(Float32List _) {}
  @override
  void reset() {}
  @override
  void finish() {}
  @override
  void close() {}
}

class _NativeBoundary {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final asrCalls = <MethodCall>[];
  final voiceCalls = <MethodCall>[];
  final speechCalls = <MethodCall>[];
  final incoming = StreamController<dynamic>.broadcast(sync: true);
  final _asrs = <OhosStreamingAsr>[];
  final _pcms = <StreamingPcmCapture>[];
  final _live = <LiveWords>[];
  final _gates = <Completer<void>>[];
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _containers = <ProviderContainer>[];
  Future<Object?> Function(MethodCall call)? answerAsr;
  Future<Object?> Function(MethodCall call)? answerVoice;

  _NativeBoundary() {
    messenger.setMockMethodCallHandler(_asrChannel, (call) async {
      asrCalls.add(call);
      return await answerAsr?.call(call);
    });
    messenger.setMockMethodCallHandler(_voiceChannel, (call) async {
      voiceCalls.add(call);
      return await answerVoice?.call(call);
    });
    messenger.setMockMethodCallHandler(_speechChannel, (call) async {
      speechCalls.add(call);
      if (call.method == 'callStart') return 'ok';
      if (call.method == 'callSpeaker') return _args(call)['on'];
      return null;
    });
  }

  ProviderContainer readyContainer({String platform = 'ohos'}) {
    final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue(platform)]);
    container.listen(ohosStreamingAsrReadyProvider, (_, _) {});
    _containers.add(container);
    return container;
  }

  void disposeReady(ProviderContainer container) {
    _containers.remove(container);
    container.dispose();
  }

  Completer<void> gate() {
    final value = Completer<void>();
    _gates.add(value);
    return value;
  }

  OhosStreamingAsr asr({bool probe = false}) {
    final value = probe ? OhosStreamingAsr.forReadiness() : OhosStreamingAsr();
    _asrs.add(value);
    return value;
  }

  StreamingPcmCapture pcm() {
    final value = StreamingPcmCapture(platformEvents: incoming.stream);
    _pcms.add(value);
    return value;
  }

  _ObservedAsr observe(OhosStreamingAsr value) {
    final observed = _ObservedAsr();
    _subscriptions.add(
      value.events.listen(observed.events.add, onError: observed.errors.add),
    );
    return observed;
  }

  LiveWords captions(
    OhosStreamingAsr recognizer,
    StreamingPcmCapture capture,
    void Function(String) onWords, {
    void Function(Object)? onFailure,
    NativeTrial? trial,
  }) {
    final value = LiveWords(
      capture,
      recognizer,
      _model,
      StreamingPcmSource.call,
      onWords,
      onFailure: onFailure,
      trial: trial,
    );
    _live.add(value);
    return value;
  }

  List<MethodCall> calls(String method) =>
      asrCalls.where((call) => call.method == method).toList();
  int get run => _args(calls('start').last)['run'] as int;
  int get session =>
      _args(
            voiceCalls.lastWhere((call) => _args(call).containsKey('source')),
          )['pcmSession']
          as int;
  int get disabledTaps =>
      voiceCalls.where((call) => !_args(call).containsKey('source')).length;

  Future<void> event(
    int eventRun,
    String type, {
    String? text,
    String? reason,
  }) async {
    await method(_asrChannel.name, 'event', {
      'run': eventRun,
      'type': type,
      if (text != null) 'text': text,
      if (reason != null) 'reason': reason,
    });
  }

  Future<void> method(
    String channel,
    String method,
    Map<String, Object?> args,
  ) async {
    const codec = StandardMethodCodec();
    final handled = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      channel,
      codec.encodeMethodCall(MethodCall(method, args)),
      (data) {
        try {
          if (data != null) codec.decodeEnvelope(data);
          handled.complete();
        } catch (error, stack) {
          handled.completeError(error, stack);
        }
      },
    );
    await handled.future;
    await _flush();
  }

  Future<void> reset(
    String reason, {
    int? eventSession,
    String source = 'call',
  }) async {
    incoming.add({
      'type': 'pcmReset',
      'pcmSession': eventSession ?? session,
      'source': source,
      'reason': reason,
    });
    await _flush();
  }

  Future<void> frame({int? eventSession, Uint8List? bytes}) async {
    incoming.add({
      'type': 'pcm',
      'pcmSession': eventSession ?? session,
      'rate': 16000,
      'bytes': bytes ?? Uint8List(640),
    });
    await _flush();
  }

  Future<void> close() async {
    for (final container in _containers) { container.dispose(); }
    _containers.clear();
    answerAsr = null;
    answerVoice = null;
    for (final pending in _gates) {
      if (!pending.isCompleted) pending.complete();
    }
    await _flush();
    for (final value in _live) {
      await value.stop().catchError((Object _) {});
    }
    for (final value in _pcms) {
      await value.dispose();
    }
    for (final value in _asrs) {
      await value.dispose();
    }
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await incoming.close();
    messenger.setMockMethodCallHandler(_asrChannel, null);
    messenger.setMockMethodCallHandler(_voiceChannel, null);
    messenger.setMockMethodCallHandler(_speechChannel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativeBoundary native;
  setUp(() {
    native = _NativeBoundary();
  });
  tearDown(() async {
    await native.close();
  });

  test(
    'system model is explicit and only the OH factory selects Core Speech',
    () async {
      expect(_model.isSystem, isTrue);
      expect([
        _model.encoder,
        _model.decoder,
        _model.joiner,
        _model.tokens,
      ], everyElement(isEmpty));
      const files = StreamingAsrModel(
        encoder: 'e.onnx',
        decoder: 'd.onnx',
        joiner: 'j.onnx',
        tokens: 'tokens.txt',
      );
      expect(files.isSystem, isFalse);
      final asr = native.asr();
      await expectLater(asr.start(files), throwsUnsupportedError);
      expect(native.asrCalls, isEmpty);
      final ohos = ProviderContainer(
        overrides: [operatingSystemProvider.overrideWithValue('ohos')],
      );
      final android = ProviderContainer(
        overrides: [operatingSystemProvider.overrideWithValue('android')],
      );
      try {
        expect(ohos.read(streamingAsrProvider), isA<OhosStreamingAsr>());
        expect(android.read(streamingAsrProvider).runtimeType, StreamingAsr);
      } finally {
        ohos.dispose();
        android.dispose();
        await _flush();
      }
    },
  );

  test(
    'partial and final events are accepted only for the current run',
    () async {
      final asr = native.asr();
      final heard = native.observe(asr);
      await asr.start(_model);
      final run = native.run;
      await native.event(run - 1, 'partial', text: 'old');
      await native.method(_asrChannel.name, 'unrelated', {
        'run': run,
        'type': 'partial',
        'text': 'ignored',
      });
      await native.event(run, 'partial', text: '你好');
      await native.event(run, 'final', text: '你好世界');
      expect(heard.events.map((event) => event.text), ['你好', '你好世界']);
      expect(heard.events.first, isA<StreamingAsrPartial>());
      expect(heard.events.last, isA<StreamingAsrFinal>());
      expect(heard.errors, isEmpty);
      await asr.stop(finalize: false);
      await native.event(run, 'final', text: 'late');
      expect(heard.events, hasLength(2));
      expect(asr.active, isFalse);
      expect(_args(native.calls('stop').single), {
        'run': run,
        'finalize': false,
      });
    },
  );

  test(
    'cancel and retry ignore a late start completion and old native errors',
    () async {
      final asr = native.asr();
      final heard = native.observe(asr);
      final firstStart = native.gate();
      native.answerAsr = (call) async {
        if (call.method == 'start' && native.calls('start').length == 1)
          await firstStart.future;
        return null;
      };
      final first = asr.start(_model);
      await _flush();
      final retired = native.run;
      await asr.stop(finalize: false);
      expect(asr.active, isFalse);
      await asr.start(_model);
      final current = native.run;
      expect(current, greaterThan(retired));
      firstStart.complete();
      await first;
      await native.event(retired, 'error', reason: 'late start failed');
      await native.event(retired, 'partial', text: 'retired');
      await native.event(current, 'partial', text: 'current');
      expect(asr.active, isTrue);
      expect(heard.errors, isEmpty);
      expect(heard.events.map((event) => event.text), ['current']);
    },
  );

  test(
    'disposing a replaced owner cannot detach the new native listener',
    () async {
      final old = native.asr();
      final oldHeard = native.observe(old);
      await old.start(_model);
      final retired = native.run;
      final current = native.asr();
      final currentHeard = native.observe(current);
      await current.start(_model);
      final run = native.run;
      expect(old.active, isFalse);
      await old.dispose();
      await native.event(retired, 'partial', text: 'wrong owner');
      await native.event(run, 'partial', text: 'new owner');
      expect(oldHeard.events, isEmpty);
      expect(currentHeard.events.single.text, 'new owner');
      expect(_args(native.calls('stop').single)['run'], retired);
      expect(current.active, isTrue);
    },
  );

  test(
    'native start and feed failures remain visible and allow a fresh retry',
    () async {
      final asr = native.asr();
      final heard = native.observe(asr);
      var failStart = true;
      var failFeed = true;
      native.answerAsr = (call) async {
        if (call.method == 'start' && failStart) {
          failStart = false;
          throw PlatformException(
            code: 'streaming_asr',
            message: 'createEngine',
          );
        }
        if (call.method == 'feed' && failFeed) {
          failFeed = false;
          throw PlatformException(code: 'streaming_asr', message: 'writeAudio');
        }
        return null;
      };
      await expectLater(asr.start(_model), throwsA(isA<PlatformException>()));
      expect(asr.active, isFalse);
      await asr.start(_model);
      final failedRun = native.run;
      await expectLater(
        asr.feed(Uint8List(640)),
        throwsA(isA<PlatformException>()),
      );
      await _flush();
      expect(heard.errors, hasLength(1));
      expect(asr.active, isFalse);
      expect(_args(native.calls('stop').last), {
        'run': failedRun,
        'finalize': false,
      });
      await asr.start(_model);
      await asr.feed(Uint8List(640));
      expect(asr.active, isTrue);
    },
  );

  test(
    'feed enforces 640 bytes and sends an owned copy on the same run',
    () async {
      final asr = native.asr();
      native.observe(asr);
      await asr.start(_model);
      for (final length in [0, 2, 639, 641]) {
        await expectLater(asr.feed(Uint8List(length)), throwsFormatException);
      }
      expect(native.calls('feed'), isEmpty);
      final input = Uint8List(640)..[0] = 23;
      final sending = asr.feed(input);
      input[0] = 99;
      await sending;
      expect(_args(native.calls('feed').single)['run'], native.run);
      final sent = _args(native.calls('feed').single)['bytes'] as Uint8List;
      expect(sent.length, 640);
      expect(sent[0], 23);
      expect(asr.active, isTrue);
    },
  );

  test('50 pending frames are bounded and overflow reports an error without silent loss', () async {
    final asr = native.asr();
    final heard = native.observe(asr);
    await asr.start(_model);
    final pending = native.gate();
    native.answerAsr = (call) async {
      if (call.method == 'feed') await pending.future;
      return null;
    };
    final feeds = [
      for (var index = 0; index < StreamingAsr.maxQueued; index++)
        asr.feed(Uint8List(640)),
    ];
    await _flush();
    expect(native.calls('feed'), hasLength(50));
    await expectLater(asr.feed(Uint8List(640)), throwsStateError);
    await _flush();
    expect(native.calls('feed'), hasLength(50));
    expect(heard.errors, hasLength(1));
    expect(asr.active, isFalse);
    expect(_args(native.calls('stop').single)['finalize'], isFalse);
    pending.complete();
    await Future.wait(feeds);
    await asr.start(_model);
    await asr.feed(Uint8List(640));
    expect(asr.active, isTrue);
  });

  test('tap reset requires the matching source and session and ignores retired sessions', () async {
    final pcm = native.pcm();
    final resets = <StreamingPcmReset>[];
    final subscription = pcm.resets.listen(resets.add);
    addTearDown(subscription.cancel);
    await pcm.start(StreamingPcmSource.call);
    final first = native.session;
    await native.reset('muted', source: 'dictation');
    await native.reset('muted', eventSession: first - 1);
    await native.reset('unknown');
    expect(resets, isEmpty);
    await native.reset('muted');
    await native.reset('resumed');
    await native.reset('stopped');
    expect(resets, StreamingPcmReset.values);
    await pcm.start(StreamingPcmSource.dictation);
    await native.reset('muted', eventSession: first);
    await native.reset('muted');
    expect(resets, hasLength(3));
    await native.reset('muted', source: 'dictation');
    expect(resets, hasLength(4));
    expect(resets.last, StreamingPcmReset.muted);
  });

  test(
    'the Android model keeps the original PCM stream error propagation',
    () async {
      const files = StreamingAsrModel(
        encoder: 'e',
        decoder: 'd',
        joiner: 'j',
        tokens: 't',
      );
      final errors = <Object>[];
      final failure = StateError('original PCM stream failure');
      await runZonedGuarded<Future<void>>(
        () async {
          final asr = StreamingAsr(createDecoder: _IdleDecoder.new);
          final pcm = native.pcm();
          final live = LiveWords(
            pcm,
            asr,
            files,
            StreamingPcmSource.call,
            (_) {},
          );
          try {
            await live.start();
            native.incoming.addError(failure);
            await _flush();
            expect(asr.active, isTrue);
            expect(live.failure, isNull);
          } finally {
            await live.stop();
            await asr.dispose();
          }
        },
        (Object error, StackTrace _) {
          errors.add(error);
        },
      );
      expect(
        errors,
        [same(failure)],
        reason: 'OH error handling must not swallow the original non-system stream error',
      );
    },
  );

  test('LiveWords mute clears captions and resume starts a fresh recognizer without disabling the tap', () async {
    final asr = native.asr();
    final pcm = native.pcm();
    final words = <String>[];
    final live = native.captions(asr, pcm, words.add);
    await live.start();
    final first = native.run;
    await native.event(first, 'partial', text: 'before mute');
    await native.frame();
    expect(native.calls('feed'), hasLength(1));
    await native.reset('muted');
    expect(words.last, '');
    expect(asr.active, isFalse);
    await native.frame();
    expect(native.calls('feed'), hasLength(1));
    expect(native.disabledTaps, 0);
    await native.reset('resumed');
    final current = native.run;
    expect(current, greaterThan(first));
    await native.event(first, 'final', text: 'old caption');
    await native.event(current, 'partial', text: 'after mute');
    expect(words.last, 'after mute');
    expect(words, isNot(contains('old caption')));
    await native.frame();
    expect(_args(native.calls('feed').last)['run'], current);
    expect(native.disabledTaps, 0);
    expect(live.failure, isNull);
  });

  test(
    'LiveWords ignores a retired feed failure after mute and resume',
    () async {
      final asr = native.asr();
      final pcm = native.pcm();
      final words = <String>[];
      final errors = <Object>[];
      final live = native.captions(asr, pcm, words.add, onFailure: errors.add);
      await live.start();
      final first = native.run;
      final oldFeed = native.gate();
      native.answerAsr = (call) async {
        if (call.method == 'feed' && _args(call)['run'] == first)
          await oldFeed.future;
        return null;
      };
      await native.frame();
      expect(native.calls('feed'), hasLength(1));
      await native.reset('muted');
      await native.reset('resumed');
      final current = native.run;
      expect(current, greaterThan(first));
      await native.event(current, 'partial', text: 'current caption');
      expect(words.last, 'current caption');
      oldFeed.completeError(
        PlatformException(code: 'streaming_asr', message: 'retired writeAudio'),
      );
      await _flush();
      expect(
        live.failure,
        isNull,
        reason: 'An old run cannot fail the resumed captions',
      );
      expect(errors, isEmpty);
      expect(asr.active, isTrue);
      expect(native.disabledTaps, 0);
      await native.event(current, 'final', text: 'current final');
      expect(words.last, 'current final');
    },
  );

  test('a retired feed success cannot prove the resumed NativeTrial', () async {
    final directory = await Directory.systemTemp.createTemp('ohos-asr-trial-');
    addTearDown(() async => directory.delete(recursive: true));
    final trial = NativeTrial(directory, 'test-system-asr');
    final asr = native.asr();
    final pcm = native.pcm();
    final live = native.captions(asr, pcm, (_) {}, trial: trial);
    await live.start();
    final first = native.run;
    final oldFeed = native.gate();
    native.answerAsr = (call) async {
      if (call.method == 'feed' && _args(call)['run'] == first)
        await oldFeed.future;
      return null;
    };
    await native.frame();
    await native.reset('muted');
    await native.reset('resumed');
    oldFeed.complete();
    await _flush();
    expect(
      trial.proven,
      isFalse,
      reason: 'A cancelled run has no verdict for the current run',
    );
    await native.frame();
    expect(trial.proven, isTrue);
    expect(live.failure, isNull);
    await live.stop();
  });

  test(
    'stopping during recognizer startup never enables the PCM tap later',
    () async {
      final asr = native.asr();
      final pcm = native.pcm();
      final live = native.captions(asr, pcm, (_) {});
      final loading = native.gate();
      native.answerAsr = (call) async {
        if (call.method == 'start') await loading.future;
        return null;
      };
      final starting = live.start();
      await _flush();
      await live.stop();
      loading.complete();
      await starting;
      expect(native.voiceCalls, isEmpty);
      expect(asr.active, isFalse);
    },
  );

  test('LiveWords retries a failed physical stop and coalesces concurrent stops', () async {
    final asr = native.asr();
    final pcm = native.pcm();
    final live = native.captions(asr, pcm, (_) {});
    await live.start();
    final stopping = native.gate();
    var broken = true;
    native.answerAsr = (call) async {
      if (call.method == 'stop' && broken) {
        await stopping.future;
        throw PlatformException(code: 'streaming_asr', message: 'shutdown');
      }
      return null;
    };
    final first = expectLater(live.stop(), throwsA(isA<PlatformException>()));
    final concurrent = expectLater(live.stop(), throwsA(isA<PlatformException>()));
    await _flush();
    expect(native.calls('stop'), hasLength(1));
    stopping.complete();
    await Future.wait([first, concurrent]);
    broken = false;
    await live.stop();
    expect(native.calls('stop'), hasLength(2));
    expect(native.disabledTaps, 1);
    expect(asr.active, isFalse);
  });

  test('an old LiveWords stop retry cannot stop a replacement using the same providers', () async {
    final asr = native.asr();
    final pcm = native.pcm();
    final oldWords = <String>[];
    final old = native.captions(asr, pcm, oldWords.add);
    await old.start();
    final oldRun = native.run;
    native.answerAsr = (call) async {
      if (call.method == 'stop' && _args(call)['run'] == oldRun) {
        throw PlatformException(code: 'streaming_asr', message: 'shutdown');
      }
      return null;
    };
    await expectLater(old.stop(), throwsA(isA<PlatformException>()));
    native.answerAsr = null;
    final words = <String>[];
    final current = native.captions(asr, pcm, words.add);
    await current.start();
    final currentRun = native.run;
    final currentSession = native.session;
    final stoppedTaps = native.disabledTaps;
    await old.stop();
    expect(asr.active, isTrue, reason: 'old release must not stop the current ASR run');
    expect(native.disabledTaps, stoppedTaps, reason: 'old release must not disable the current PCM tap');
    expect(native.calls('stop').where((call) => _args(call)['run'] == currentRun), isEmpty);
    await native.event(currentRun, 'partial', text: 'replacement');
    await native.frame(eventSession: currentSession);
    expect(words, ['replacement']);
    expect(oldWords, isEmpty);
    expect(_args(native.calls('feed').single)['run'], currentRun);
  });

  test('a replaced LiveWords delayed start cannot take the new tap or hear new captions', () async {
    final asr = native.asr();
    final pcm = native.pcm();
    final oldWords = <String>[];
    final old = native.captions(asr, pcm, oldWords.add);
    final pending = native.gate();
    native.answerAsr = (call) async {
      if (call.method == 'start' && native.calls('start').length == 1) await pending.future;
      return null;
    };
    final opening = expectLater(old.start(), throwsStateError);
    await _flush();
    final words = <String>[];
    final current = native.captions(asr, pcm, words.add);
    await current.start();
    final run = native.run;
    final session = native.session;
    pending.complete();
    await opening;
    await old.stop();
    expect(asr.active, isTrue);
    expect(native.session, session);
    expect(native.disabledTaps, 0);
    await native.event(run, 'partial', text: 'only current');
    await native.frame(eventSession: session);
    expect(words, ['only current']);
    expect(oldWords, isEmpty);
    expect(native.calls('feed'), hasLength(1));
  });

  test('system LiveWords is single use and stop before start cannot leak a run', () async {
    final asr = native.asr();
    final pcm = native.pcm();
    final live = native.captions(asr, pcm, (_) {});
    await live.start();
    final run = native.run;
    final session = native.session;
    await expectLater(live.start(), throwsStateError);
    expect(native.run, run);
    expect(native.session, session);
    expect(asr.active, isTrue);
    await live.stop();
    final stopped = native.captions(asr, pcm, (_) {});
    await stopped.stop();
    await expectLater(stopped.start(), throwsStateError);
    expect(native.run, run);
    expect(asr.active, isFalse);
  });

  test('OH ready provider probes the real external-PCM channel without a model or microphone', () async {
    final container = native.readyContainer();
    expect(await container.read(ohosStreamingAsrReadyProvider.future), SystemAsrReadiness.ready);
    expect(native.calls('start'), hasLength(1));
    expect(native.calls('stop'), hasLength(1));
    expect(_args(native.calls('stop').single), {'run': native.run, 'finalize': false});
    expect(native.calls('feed'), isEmpty);
    expect(native.voiceCalls, isEmpty);
    expect(native.speechCalls, isEmpty);
  });

  test('ready provider leaves Android and an already active OH recognizer untouched', () async {
    final android = native.readyContainer(platform: 'android');
    expect(await android.read(ohosStreamingAsrReadyProvider.future), SystemAsrReadiness.unavailable);
    expect(native.asrCalls, isEmpty);
    final asr = native.asr();
    await asr.start(_model);
    final run = native.run;
    final ohos = native.readyContainer();
    expect(await ohos.read(ohosStreamingAsrReadyProvider.future), SystemAsrReadiness.ready);
    expect(native.calls('start'), hasLength(1));
    expect(native.calls('stop'), isEmpty);
    expect(native.run, run);
    expect(asr.active, isTrue);
  });

  test('ready provider reports busy without replacing an in-flight real caption start', () async {
    final asr = native.asr();
    final pending = native.gate();
    native.answerAsr = (call) async {
      if (call.method == 'start') await pending.future;
      return null;
    };
    final opening = asr.start(_model);
    await _flush();
    final run = native.run;
    final container = native.readyContainer();
    expect(await container.read(ohosStreamingAsrReadyProvider.future), SystemAsrReadiness.busy);
    expect(native.calls('start'), hasLength(1));
    expect(native.calls('stop'), isEmpty);
    pending.complete();
    await opening;
    expect(asr.active, isTrue);
    expect(native.run, run);
  });

  test('ready provider reports busy while a physical stop is still pending', () async {
    final asr = native.asr();
    await asr.start(_model);
    final pending = native.gate();
    native.answerAsr = (call) async {
      if (call.method == 'stop') await pending.future;
      return null;
    };
    final stopping = asr.stop(finalize: false);
    await _flush();
    final container = native.readyContainer();
    expect(await container.read(ohosStreamingAsrReadyProvider.future), SystemAsrReadiness.busy);
    expect(native.calls('start'), hasLength(1));
    expect(native.calls('stop'), hasLength(1));
    pending.complete();
    await stopping;
  });

  test('late readiness probe cleanup cannot stop a newer real caption', () async {
    final pending = native.gate();
    native.answerAsr = (call) async {
      if (call.method == 'start' && native.calls('start').length == 1) await pending.future;
      return null;
    };
    final container = native.readyContainer();
    final ready = container.read(ohosStreamingAsrReadyProvider.future);
    await _flush();
    final probeRun = native.run;
    final asr = native.asr();
    final heard = native.observe(asr);
    await asr.start(_model);
    final current = native.run;
    pending.complete();
    expect(await ready, SystemAsrReadiness.ready);
    expect(_args(native.calls('stop').single)['run'], probeRun);
    expect(asr.active, isTrue);
    await native.event(current, 'partial', text: 'current');
    expect(heard.events.single.text, 'current');
  });

  test('disposing an in-flight ready probe cancels only its own run', () async {
    final pending = native.gate();
    native.answerAsr = (call) async {
      if (call.method == 'start' && native.calls('start').length == 1) await pending.future;
      return null;
    };
    final container = native.readyContainer();
    final ready = container.read(ohosStreamingAsrReadyProvider.future);
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    await _flush();
    final probeRun = native.run;
    native.disposeReady(container);
    await _flush();
    expect(_args(native.calls('stop').single)['run'], probeRun);
    final asr = native.asr();
    final heard = native.observe(asr);
    await asr.start(_model);
    final current = native.run;
    pending.complete();
    await _flush();
    expect(asr.active, isTrue);
    expect(native.calls('stop'), hasLength(1));
    await native.event(current, 'partial', text: 'after disposed probe');
    expect(heard.events.single.text, 'after disposed probe');
  });

  test('a readiness probe that has started is still busy to another probe', () async {
    final probe = native.asr(probe: true);
    await probe.start(_model);
    expect(probe.active, isTrue);
    final container = native.readyContainer();
    expect(await container.read(ohosStreamingAsrReadyProvider.future), SystemAsrReadiness.busy);
    expect(native.calls('start'), hasLength(1));
    expect(native.calls('stop'), isEmpty);
  });

  for (final failReply in [false, true]) {
    test('ready provider observes native error with failed start reply=$failReply', () async {
      native.answerAsr = (call) async {
        if (call.method == 'start') {
          await native.event(_args(call)['run'] as int, 'error', reason: 'createEngine');
          if (failReply) throw PlatformException(code: 'streaming_asr', message: 'createEngine');
        }
        return null;
      };
      final container = native.readyContainer();
      await expectLater(container.read(ohosStreamingAsrReadyProvider.future), throwsA(isA<PlatformException>()));
      expect(native.calls('start'), hasLength(1));
      expect(native.calls('stop'), isNotEmpty);
      expect(native.voiceCalls, isEmpty);
    });
  }

  test('ready provider preserves native unavailable and shutdown failures for retry', () async {
    native.answerAsr = (call) async {
      if (call.method == 'start') throw PlatformException(code: 'streaming_asr', message: 'busy');
      return null;
    };
    final unavailable = native.readyContainer();
    await expectLater(unavailable.read(ohosStreamingAsrReadyProvider.future), throwsA(isA<PlatformException>()));
    expect(native.voiceCalls, isEmpty);
    native.disposeReady(unavailable);
    native.answerAsr = (call) async {
      if (call.method == 'stop') throw PlatformException(code: 'streaming_asr', message: 'shutdown');
      return null;
    };
    final closing = native.readyContainer();
    await expectLater(closing.read(ohosStreamingAsrReadyProvider.future), throwsA(isA<PlatformException>()));
    native.disposeReady(closing);
    native.answerAsr = null;
    final retry = native.readyContainer();
    expect(await retry.read(ohosStreamingAsrReadyProvider.future), SystemAsrReadiness.ready);
  });

  test('caption failure stops only its tap and leaves the real call controller active', () async {
    final audio = SpeechAudio();
    final call = VoiceCallController(
      audio: audio,
      conversation: FakeConversation(),
      recognizer: () async => FakeCloud(),
      voice: FakeOut.new,
      choices: () async => (
        bargeIn: true,
        speaker: true,
        spokenHint: null,
        pause: CallPause.quick,
      ),
    );
    addTearDown(() {
      call.dispose();
      audio.dispose();
    });
    await call.start();
    expect(call.phase, CallPhase.listening);
    final asr = native.asr();
    final pcm = native.pcm();
    final failures = <Object>[];
    final live = native.captions(asr, pcm, call.live, onFailure: failures.add);
    await live.start();
    await native.method(_speechChannel.name, 'event', {
      'type': 'speechStart',
      'over': false,
    });
    await native.event(native.run, 'partial', text: '正在通话');
    expect(call.heard, '正在通话');
    await native.event(native.run, 'error', reason: 'recognizer unavailable');
    await _flush();
    expect(live.failure, isA<PlatformException>());
    expect(failures, hasLength(1));
    expect(call.phase, CallPhase.hearing);
    expect(call.ended, isNull);
    expect(call.heard, isEmpty);
    expect(
      native.speechCalls.where((value) => value.method == 'callStop'),
      isEmpty,
    );
    expect(native.disabledTaps, 1);
    await native.method(_speechChannel.name, 'event', {
      'type': 'micLevel',
      'value': 0.75,
    });
    expect(call.micLevel, 0.75);
    call.hangUp();
    await _flush();
    expect(
      native.speechCalls.where((value) => value.method == 'callStop'),
      hasLength(1),
    );
  });
}
